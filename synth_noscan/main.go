// synth_noscan allocates a large amount of pointer-free ("noscan") Go data and
// reports VmRSS and runtime.MemStats at each phase. Run it under different
// GONOSCANFILE configurations to compare the anonymous heap against the
// file-backed noscan region, with and without MADV_PAGEOUT.
//
// The data is []byte, which is noscan, so when GONOSCANFILE is set it is served
// from the file region; otherwise it comes from the regular anonymous heap.
//
// Phases:
//
//	init                     before allocating anything
//	fill_live                allocate N objects of -obj bytes each, kept live
//	after_gc_settle          runtime.GC() + wait for background sweep/pageout
//	churnR_drop              (optional) drop half the live objects, GC+settle
//	churnR_realloc           (optional) reallocate the dropped half, GC+settle
//	retouch_refault          re-read every page of all live data (re-fault cost)
//
// The interesting comparison across configs:
//
//   - baseline: after_gc_settle RSS ~ fill_live (anonymous live data can never
//     be evicted with no swap).
//   - file (pageout off): same as baseline (mapping resident, costs nothing
//     extra).
//   - pageout: after_gc_settle RSS drops by ~total (live region pages evicted
//     to the file); retouch_refault is slower (re-faults from disk).
package main

import (
	"flag"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
)

var (
	flagTotal   = flag.String("total", "1GiB", "total noscan bytes to allocate (kept live)")
	flagObj     = flag.String("obj", "256KiB", "size of each noscan object")
	flagSettle  = flag.Duration("settle", 1500*time.Millisecond, "max time to wait for background sweep+pageout after GC")
	flagChurn   = flag.Int("churn", 0, "number of churn rounds (drop half + realloc)")
	flagNoTouch = flag.Bool("no-retouch", false, "skip the re-touch (re-fault) phase")
)

func main() {
	flag.Parse()

	total, err := parseMemSize(*flagTotal)
	if err != nil {
		fail("bad -total %q: %v", *flagTotal, err)
	}
	obj, err := parseMemSize(*flagObj)
	if err != nil {
		fail("bad -obj %q: %v", *flagObj, err)
	}
	if obj <= 0 || total <= 0 {
		fail("sizes must be positive")
	}
	n := int(total / obj)

	// Self-labeling banner: which region config this run uses.
	fmt.Printf("# synth_noscan total=%s obj=%s n=%d objects\n", *flagTotal, *flagObj, n)
	fmt.Printf("# GONOSCANFILE=%s GONOSCANFILESIZE=%s GONOSCANPAGEOUT=%s GONOSCANFILEMIN=%s\n",
		envOr("GONOSCANFILE", "(unset)"),
		envOr("GONOSCANFILESIZE", "(unset)"),
		envOr("GONOSCANPAGEOUT", "(unset=on)"),
		envOr("GONOSCANFILEMIN", "(unset=0)"))
	printHeader()

	var live [][]byte
	measure("init")

	// Phase 1: allocate and dirty N noscan objects, all kept referenced.
	t0 := time.Now()
	live = make([][]byte, 0, n)
	for i := 0; i < n; i++ {
		b := make([]byte, obj)
		dirty(b)
		live = append(live, b)
	}
	measureDur("fill_live", time.Since(t0))

	// Phase 2: GC + settle so the background sweep's pageoutFileRegion() runs.
	gcAndSettle(*flagSettle, "after_gc_settle")

	// Phase 3 (optional): churn. Drop half, settle, reallocate, settle. This
	// exercises the free-time zero+evict path for the pageout config.
	for r := 1; r <= *flagChurn; r++ {
		half := len(live) / 2
		live = live[:half] // second half becomes garbage
		gcAndSettle(*flagSettle, fmt.Sprintf("churn%d_drop", r))
		for i := 0; i < half; i++ {
			b := make([]byte, obj)
			dirty(b)
			live = append(live, b)
		}
		gcAndSettle(*flagSettle, fmt.Sprintf("churn%d_realloc", r))
	}

	// Phase 4: re-touch every page of all live data. For the pageout config
	// this forces re-faults from the backing file (disk); for baseline the
	// pages never left RAM so it is a cache hit.
	if !*flagNoTouch {
		t0 = time.Now()
		var check byte
		for _, b := range live {
			for p := 0; p < len(b); p += 4096 {
				check ^= b[p]
			}
		}
		sink = check // prevent dead-code elimination
		measureDur("retouch_refault", time.Since(t0))
	}

	runtime.KeepAlive(live)
}

// sink absorbs the re-touch checksum so the reads are not optimized away.
var sink byte

// dirty writes one non-zero byte per page so every page is resident and the
// file (for the pageout config) holds real content rather than sparse zeros.
func dirty(b []byte) {
	for p := 0; p < len(b); p += 4096 {
		b[p] = 0xAB
	}
	if len(b) > 0 {
		b[len(b)-1] = 0xCD
	}
}

// gcAndSettle forces a GC cycle and then polls VmRSS until it stabilizes (3
// identical samples) or max elapses. The background sweep goroutine calls
// pageoutFileRegion() once sweeping is done, which is what drives the RSS drop
// for the pageout config.
func gcAndSettle(max time.Duration, label string) {
	t0 := time.Now()
	runtime.GC()
	const sample = 50 * time.Millisecond
	prev := int64(-1)
	stable := 0
	deadline := time.Now().Add(max)
	for time.Now().Before(deadline) {
		time.Sleep(sample)
		rss, _ := vmStat()
		if rss == prev {
			stable++
		} else {
			stable = 0
		}
		if stable >= 3 {
			break
		}
		prev = rss
	}
	measureDur(label, time.Since(t0))
}

// --- measurement helpers ---

func printHeader() {
	fmt.Printf("%-18s %10s %9s %9s %14s %15s\n",
		"phase", "dur", "rss_MiB", "hwm_MiB", "heapAlloc_MiB", "heapInuse_MiB")
}

func measure(phase string) { measureDur(phase, 0) }

func measureDur(phase string, dur time.Duration) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	rss, hwm := vmStat()
	fmt.Printf("%-18s %10s %9.1f %9.1f %14.1f %15.1f\n",
		phase, durStr(dur),
		float64(rss)/1024, float64(hwm)/1024,
		float64(ms.HeapAlloc)/1024/1024, float64(ms.HeapInuse)/1024/1024)
}

func durStr(d time.Duration) string {
	if d == 0 {
		return "-"
	}
	return d.Truncate(time.Millisecond).String()
}

// vmStat returns VmRSS and VmHWM in kB from /proc/self/status.
func vmStat() (rss, hwm int64) {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0, 0
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "VmRSS:") {
			fmt.Sscanf(line, "VmRSS: %d kB", &rss)
		} else if strings.HasPrefix(line, "VmHWM:") {
			fmt.Sscanf(line, "VmHWM: %d kB", &hwm)
		}
	}
	return rss, hwm
}

func parseMemSize(s string) (int64, error) {
	s = strings.TrimSpace(s)
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	if i == 0 {
		return 0, fmt.Errorf("no leading digits")
	}
	n, err := strconv.ParseInt(s[:i], 10, 64)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("bad number: %w", err)
	}
	var mul int64 = 1
	switch strings.ToLower(s[i:]) {
	case "", "b":
		mul = 1
	case "k", "kb", "kib":
		mul = 1 << 10
	case "m", "mb", "mib":
		mul = 1 << 20
	case "g", "gb", "gib":
		mul = 1 << 30
	default:
		return 0, fmt.Errorf("unknown suffix %q", s[i:])
	}
	return n * mul, nil
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "synth_noscan: "+format+"\n", a...)
	os.Exit(2)
}
