#!/bin/bash
#
# etcd_noscan_file_bench.sh — etcd noscan file-region benchmark (FILE-backed).
#
# Builds etcd + benchmark tool with the in-tree Go toolchain, then runs five
# benchmark scenarios under three configurations, collecting throughput,
# latency and memory metrics. The "memory saved" story here is purely about
# RAM: moving noscan data into a regular file and evicting its pages with
# MADV_PAGEOUT so they leave DRAM (spilling to disk), versus keeping them in
# the anonymous heap.
#
# This is the disk-backed variant of doc/etcd_noscan_bench.sh. There is no
# zram on the machine, so there is no compression: the file region either
# stays resident (pageout off) or is evicted to the file on disk (pageout on).
#
# Configurations:
#   baseline  No GONOSCANFILE. Ordinary anonymous heap.            (control)
#   file      GONOSCANFILE=<file>, pageout=OFF. Region mapped but
#             pages stay resident -> RSS ~ baseline (shows the mapping
#             itself costs almost nothing).
#   pageout   GONOSCANFILE=<file>, pageout=ON, GONOSCANFILEMIN=256.
#             Freed spans are zeroed + MADV_PAGEOUT'd, and live spans are
#             evicted after each sweep. Cold noscan data leaves DRAM and
#             spills to the file -> lower RSS at the cost of disk re-fault.
#
# Usage:
#   ./etcd_noscan_file_bench.sh [OPTIONS]
#
# Options:
#   --goroot DIR       Go source tree root        (default: inferred)
#   --etcd-root DIR    etcd source tree           (default: ~/dev/etcd)
#   --results DIR      Output directory            (default: ./results_file)
#   --file PATH        Backing file path           (default: /tmp/noscan.bin)
#   --region SIZE      GONOSCANFILESIZE            (default: 128MiB)
#   --conns N          gRPC connections            (default: 100)
#   --clients N        gRPC clients                (default: 500)
#   --skip-build       Use existing binaries       (skip build step)
#   --only CONFIG      Run only one config         (baseline|file|pageout)
#   -h, --help         Show this help
#
# Prerequisites:
#   - The Go source tree (GOROOT) with the noscan file region patches.
#   - The etcd source tree (a 3.5.x tag buildable with GOROOT's Go, e.g. v3.5.18).
#   - The backing-file directory must be on real disk (ext4 etc.), NOT tmpfs,
#     otherwise pages "evicted to disk" land in RAM-backed page cache and the
#     experiment measures nothing useful. /tmp on this machine is ext4 -> OK.
#
# Example:
#   ./etcd_noscan_file_bench.sh \
#       --goroot /home/orangepi/ws/go2 \
#       --etcd-root /home/orangepi/ws/etcd-work/etcd-3.5.18 \
#       --skip-build
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
GOROOT=""
ETCD_ROOT="$HOME/dev/etcd"
RESULTS="./results_file"
FILE="/tmp/noscan.bin"
REGION_SIZE="128MiB"
CONNS=100
CLIENTS=500
SKIP_BUILD=0
ONLY=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --goroot)      GOROOT="$2"; shift 2 ;;
    --etcd-root)   ETCD_ROOT="$2"; shift 2 ;;
    --results)     RESULTS="$2"; shift 2 ;;
    --file)        FILE="$2"; shift 2 ;;
    --region)      REGION_SIZE="$2"; shift 2 ;;
    --conns)       CONNS="$2"; shift 2 ;;
    --clients)     CLIENTS="$2"; shift 2 ;;
    --skip-build)  SKIP_BUILD=1; shift ;;
    --only)        ONLY="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,/^$/s/^# \?//p' "$0"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Infer GOROOT from the script location if not set.
if [[ -z "$GOROOT" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [[ -f "$SCRIPT_DIR/../src/runtime/memfile.go" ]]; then
    GOROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  else
    echo "ERROR: cannot infer GOROOT; pass --goroot" >&2
    exit 1
  fi
fi

GO_BIN="$GOROOT/bin/go"
GO_ENV="PATH=$GOROOT/bin:/usr/local/go/bin:/usr/bin:/bin"
GO_ENV+=" GOROOT=$GOROOT GOTOOLCHAIN=local"
GO_ENV+=" GOCACHE=${GOCACHE:-$HOME/.cache/go-build}"
GO_ENV+=" GOMODCACHE=${GOMODCACHE:-$HOME/go/pkg/mod}"
GO_ENV+=" GOPATH=${GOPATH:-$HOME/go}"
GO_ENV+=" CGO_ENABLED=0"

ETCD_BIN="$ETCD_ROOT/bin/etcd"
ETCDCTL_BIN="$ETCD_ROOT/bin/etcdctl"
BENCH_BIN="$ETCD_ROOT/bin/benchmark"
DATADIR="/tmp/etcd-bench-data"

# Per-run state (set by start_etcd, read by the metric helpers).
ETCD_PID=""
RESET_BACKING=""   # when non-empty, start_etcd removes $FILE first

mkdir -p "$RESULTS"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date +%H:%M:%S)] $*"; }

# VmRSS / VmHWM in kB from /proc/PID/status.
get_rss() { awk '/^VmRSS:/{print $2}' /proc/$1/status 2>/dev/null; }
get_hwm() { awk '/^VmHWM:/{print $2}' /proc/$1/status 2>/dev/null; }

# Resident pages (kB) of the file-backed region mapping in /proc/PID/smaps.
# A process normally has exactly one mapping whose line contains $FILE; we sum
# Rss over any such mappings (robust to the kernel splitting the VMA).
smaps_region_rss() {
  awk -v f="$FILE" '
    /^[0-9a-f]+-[0-9a-f]+ / { hit = (index($0, f) > 0) }
    hit && /^Rss:/ { sum += $2 }
    END { print sum+0 }
  ' /proc/$1/smaps 2>/dev/null
}

# Actual on-disk size of the backing file in KiB (allocated blocks, not
# apparent/sparse size). `sync` is called by the caller first so dirty
# writeback (incl. MADV_PAGEOUT'd pages) is flushed.
file_disk_kib() {
  [[ -f "$FILE" ]] || { echo 0; return; }
  du -k "$FILE" 2>/dev/null | awk '{print $1}'
}

start_etcd() {
  local label=$1

  # The runtime only ftruncate()s a regular file to the requested size; it does
  # NOT zero an existing file, and only the *newly extended* pages are zero.
  # Reusing a stale file would leave old data in the region and break the
  # zero-on-first-use assumption, so remove it and let the runtime recreate it.
  [[ -n "$RESET_BACKING" ]] && rm -f "$FILE"

  rm -rf "$DATADIR"; mkdir -p "$DATADIR"
  env -i PATH=/usr/bin:/bin ${NOSCAN_ENV:-} \
    "$ETCD_BIN" --name single \
    --listen-client-urls http://127.0.0.1:2379 \
    --advertise-client-urls http://127.0.0.1:2379 \
    --listen-peer-urls http://127.0.0.1:12380 \
    --initial-advertise-peer-urls http://127.0.0.1:12380 \
    --initial-cluster 'single=http://127.0.0.1:12380' \
    --initial-cluster-state new --initial-cluster-token etcd-bench \
    --data-dir "$DATADIR" --logger=zap --log-outputs=discard \
    > "$RESULTS/${label}_etcd.log" 2>&1 &
  ETCD_PID=$!
  for i in $(seq 1 60); do
    if "$ETCDCTL_BIN" --endpoints=127.0.0.1:2379 endpoint health \
        >/dev/null 2>&1; then return 0; fi
    kill -0 "$ETCD_PID" 2>/dev/null \
      || { log "FAIL: etcd died ($label)"; tail -10 "$RESULTS/${label}_etcd.log"; return 1; }
    sleep 0.5
  done
  log "FAIL: etcd not ready ($label)"; return 1
}

stop_etcd() {
  kill "$ETCD_PID" 2>/dev/null || true
  wait "$ETCD_PID" 2>/dev/null || true
  sleep 1
}

# Collect all post-run metrics into ${label}_metrics.txt (values in kB).
collect_metrics() {
  local label=$1 desc=$2 rss_b=$3
  sync
  local rss_a hwm_a region file_kb
  rss_a=$(get_rss "$ETCD_PID")
  hwm_a=$(get_hwm "$ETCD_PID")
  region=$(smaps_region_rss "$ETCD_PID")
  file_kb=$(file_disk_kib)
  cat > "$RESULTS/${label}_metrics.txt" << EOF
label=$label
desc=$desc
rss_before=$rss_b
rss_after=$rss_a
hwm_after=$hwm_a
region_rss=$region
file_disk_kib=$file_kb
EOF
  log "DONE $label  RSS ${rss_b}->${rss_a} kB (peak ${hwm_a})  region_rss=${region} kB  file=${file_kb} kB"
}

run_bench() {
  local label=$1 desc=$2; shift 2
  log "START $label: $desc"
  start_etcd "$label" || return 1

  local rss_b
  rss_b=$(get_rss "$ETCD_PID")

  "$BENCH_BIN" "$@" > "$RESULTS/${label}_bench.txt" 2>&1 || true

  collect_metrics "$label" "$desc" "$rss_b"
  stop_etcd
}

run_range() {
  local label=$1
  log "START $label: Range (after 10 K preload)"
  start_etcd "$label" || return 1

  "$BENCH_BIN" --conns=$CONNS --clients=$CLIENTS --target-leader \
    put --key-size=8 --val-size=256 --total=10000 \
    --key-space-size=10000 --sequential-keys \
    > "$RESULTS/${label}_preload.txt" 2>&1 || true

  local rss_b
  rss_b=$(get_rss "$ETCD_PID")

  "$BENCH_BIN" --conns=$CONNS --clients=$CLIENTS \
    range single-key --total=100000 \
    > "$RESULTS/${label}_bench.txt" 2>&1 || true

  collect_metrics "$label" "Range-after-10K-preload" "$rss_b"
  stop_etcd
}

# ---------------------------------------------------------------------------
# Build step
# ---------------------------------------------------------------------------
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  log "Building etcd, etcdctl, benchmark with in-tree Go ($GOROOT)..."

  ( cd "$ETCD_ROOT/server" && \
    env $GO_ENV go build -trimpath -installsuffix=cgo -o "$ETCD_BIN" . ) || {
      log "FAIL: cannot build etcd"; exit 1; }
  log "  etcd:     $ETCD_BIN"

  ( cd "$ETCD_ROOT/etcdctl" && \
    env $GO_ENV go build -trimpath -installsuffix=cgo -o "$ETCDCTL_BIN" . ) || {
      log "FAIL: cannot build etcdctl"; exit 1; }
  log "  etcdctl:  $ETCDCTL_BIN"

  ( cd "$ETCD_ROOT/tools/benchmark" && \
    env $GO_ENV go build -trimpath -installsuffix=cgo -o "$BENCH_BIN" . ) || {
      log "FAIL: cannot build benchmark"; exit 1; }
  log "  benchmark: $BENCH_BIN"
else
  for b in "$ETCD_BIN" "$ETCDCTL_BIN" "$BENCH_BIN"; do
    [[ -x "$b" ]] || { log "FAIL: missing binary $b (run without --skip-build)"; exit 1; }
  done
fi

# Sanity check
"$ETCD_BIN" --version 2>&1 | head -1

# Sanity check that the backing file is NOT on tmpfs (otherwise eviction
# "to disk" is meaningless). Allow override only if the user insists.
FSTYPE=$(findmnt -no FSTYPE "$(dirname "$FILE")" 2>/dev/null || echo unknown)
if [[ "$FSTYPE" == "tmpfs" || "$FSTYPE" == "ramfs" ]]; then
  log "ERROR: backing file dir is $FSTYPE (RAM-backed); use a real-disk path. Aborting."
  exit 1
fi
log "backing file dir fstype = $FSTYPE"

# Clear any stale backing file so the baseline config (which does not use it)
# does not report leftover disk usage from a previous, possibly-aborted run.
rm -f "$FILE"

# ---------------------------------------------------------------------------
# Run benchmarks
# ---------------------------------------------------------------------------
BENCH_ARGS="--conns=$CONNS --clients=$CLIENTS --target-leader"
SCENARIOS=(
  "put_small  Put_8B_val    put --key-size=8 --val-size=8 --total=100000 --key-space-size=100000 --sequential-keys"
  "put_medium Put_256B_val  put --key-size=8 --val-size=256 --total=100000 --key-space-size=100000 --sequential-keys"
  "put_large  Put_4KB_val   put --key-size=8 --val-size=4096 --total=10000 --key-space-size=10000 --sequential-keys"
  # stm = etcd's mixed read/write workload (STM transactions). etcd 3.5's
  # benchmark tool has no "txn-mixed" subcommand; stm is the equivalent.
  "stm        STM-mixed     stm --keys=1000 --total=10000 --val-size=256"
)

run_config() {
  # $1 = config prefix (e.g. base / file / pgout), $2.. = scenario triples
  local prefix=$1; shift
  for triple in "$@"; do
    # split triple into name / desc / rest
    set -- $triple
    local sname=$1 sdesc=$2; shift 2
    run_bench "${prefix}_${sname}" "$sdesc" $BENCH_ARGS "$@"
  done
  # range is special (preload then read)
  run_range "${prefix}_range"
}

# --- Baseline ---
if [[ "$ONLY" == "" || "$ONLY" == "baseline" ]]; then
  export NOSCAN_ENV=""
  export RESET_BACKING=""
  log "=== BASELINE (anonymous heap) ==="
  run_config base "${SCENARIOS[@]}"
fi

# --- File region, pageout OFF ---
if [[ "$ONLY" == "" || "$ONLY" == "file" ]]; then
  export NOSCAN_ENV="GONOSCANFILE=$FILE GONOSCANFILESIZE=$REGION_SIZE GONOSCANPAGEOUT=0"
  export RESET_BACKING=1
  log "=== FILE ($FILE, $REGION_SIZE, pageout=off) ==="
  run_config file "${SCENARIOS[@]}"
fi

# --- File region, pageout ON + min size filter ---
if [[ "$ONLY" == "" || "$ONLY" == "pageout" ]]; then
  export NOSCAN_ENV="GONOSCANFILE=$FILE GONOSCANFILESIZE=$REGION_SIZE GONOSCANFILEMIN=256"
  export RESET_BACKING=1
  log "=== PAGEOUT ($FILE, $REGION_SIZE, pageout=on, min=256) ==="
  run_config pgout "${SCENARIOS[@]}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "=== GENERATING SUMMARY ==="
SUMMARY="$RESULTS/summary.txt"
{
  echo "# etcd noscan FILE-region benchmark summary"
  echo "# $(date)"
  echo "# GOROOT=$GOROOT  ETCD_ROOT=$ETCD_ROOT"
  echo "# file=$FILE  region=$REGION_SIZE  conns=$CONNS  clients=$CLIENTS  fstype=$FSTYPE"
  echo "#"
  echo "# rss/dRSS/region in kB; file_disk in MiB (actual blocks)."
  echo ""
  printf "%-22s %-8s %10s %9s %9s %11s %10s %11s %11s\n" \
    "scenario" "config" "req/s" "p50(ms)" "p99(ms)" "rss_after" "dRSS" "region_rss" "file_MiB"
  printf '%0.s-' {1..110}; echo ""

  for cfg in base file pgout; do
    for s in put_small put_medium put_large range stm; do
      label="${cfg}_${s}"
      bench_file="$RESULTS/${label}_bench.txt"
      metrics_file="$RESULTS/${label}_metrics.txt"
      [[ -f "$bench_file" && -f "$metrics_file" ]] || continue

      # `|| true` so a missing percentile line (e.g. a failed bench) does not
      # abort the summary under `set -e -o pipefail`.
      reqs=$(grep -m1 'Requests/sec' "$bench_file" 2>/dev/null | awk '{printf "%.0f", $2}' || true)
      p50=$(grep -m1 '50% in' "$bench_file" 2>/dev/null | awk '{printf "%.1f", $3*1000}' || true)
      p99=$(grep -m1 '99% in' "$bench_file" 2>/dev/null | awk '{printf "%.1f", $3*1000}' || true)
      rss_b=$(awk -F= '/rss_before/{print $2}' "$metrics_file")
      rss_a=$(awk -F= '/rss_after/{print $2}' "$metrics_file")
      region=$(awk -F= '/region_rss/{print $2}' "$metrics_file")
      file_kb=$(awk -F= '/file_disk_kib/{print $2}' "$metrics_file")
      drss=$(( ${rss_a:-0} - ${rss_b:-0} ))
      file_mib=$(awk -v k="${file_kb:-0}" 'BEGIN{printf "%.1f", k/1024}')

      printf "%-22s %-8s %10s %9s %9s %11s %10s %11s %11s\n" \
        "$s" "$cfg" "${reqs:-N/A}" "${p50:-N/A}" "${p99:-N/A}" \
        "${rss_a:-N/A}" "$drss" "${region:-N/A}" "$file_mib"
    done
  done

  # Memory savings: pageout vs baseline per scenario.
  echo ""
  echo "# RAM savings (baseline_rss_after - pageout_rss_after), positive = pageout used less RAM"
  printf "%-22s %12s %12s %12s\n" "scenario" "base(MiB)" "pgout(MiB)" "saved(MiB)"
  printf '%0.s-' {1..60}; echo ""
  for s in put_small put_medium put_large range stm; do
    b=$(awk -F= '/rss_after/{print $2}' "$RESULTS/base_${s}_metrics.txt" 2>/dev/null)
    p=$(awk -F= '/rss_after/{print $2}' "$RESULTS/pgout_${s}_metrics.txt" 2>/dev/null)
    [[ -n "$b" && -n "$p" ]] || continue
    bm=$(awk -v k="$b" 'BEGIN{printf "%.1f", k/1024}')
    pm=$(awk -v k="$p" 'BEGIN{printf "%.1f", k/1024}')
    saved=$(awk -v x="$b" -v y="$p" 'BEGIN{printf "%.1f", (x-y)/1024}')
    printf "%-22s %12s %12s %12s\n" "$s" "$bm" "$pm" "$saved"
  done
} | tee "$SUMMARY"

# Final cleanup of the (now-unused) backing file.
rm -f "$FILE"

log "=== ALL DONE ==="
log "Results:   $RESULTS/"
log "Summary:   $SUMMARY"
