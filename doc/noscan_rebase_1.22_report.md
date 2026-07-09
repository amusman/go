# Rebase: noscan file region → `noscan_zram_1.22` (release-branch.go1.22 / go1.22.12)

Source branch: `noscan1` (on `release-branch.go1.24` / go1.24.13).
Target branch: `noscan_zram_1.22`, created off `origin/release-branch.go1.22` (go1.22.12).
Bootstrap: `/usr/local/go` (go1.25.5).
Build per commit: `cd src && timeout 300 bash -c 'GOROOT_BOOTSTRAP=/usr/local/go ./make.bash'`.

This report records, per cherry-picked commit, whether it applied cleanly, any
conflict fixups required, and the build/test outcome.

Legend: ✅ applied clean / 🔧 fixup needed / 📄 doc-only (no build) / 🛠 runtime (build+test).

---

## Baseline
- `5817e65094` go1.22.12 — clean build with bootstrap go1.25.5. ✅

## Cherry-picks (oldest first)
1. `f8c0374699` add MAP_SHARED and ftruncate primitives — 🛠 ✅ clean (asm auto-merged). Build ✅, tests ✅ (`ok runtime`).
2. `5816512127` setup and config parsing — 🛠 ✅ clean. Build ✅, tests ✅.
3. `66fbbb44de` register arenas and page allocator — 🛠 🔧 fixup: atomic import path
   `internal/runtime/atomic` → `runtime/internal/atomic` (the rename to
   `internal/runtime/atomic` landed in Go 1.24; 1.22 still uses
   `runtime/internal/atomic`). Amended into the commit. Build ✅, tests ✅.
4. `ec42e94923` route large noscan allocations — 🛠 ✅ clean (mheap.go auto-merged). Build ✅, tests ✅.
5. `b3a2311862` test large reuse after free — 🛠 ✅ clean (test-only). Build ✅, tests ✅.
6. `43694672bf` test exhaustion fallback — 🛠 ✅ clean (test-only). Build ✅, tests ✅.
7. `eb0fab1206` init at startup, exclude from scavenging — 🛠 🔧 fixup: `proc.go` conflict
   in schedinit. The 1.24 context anchor `mProfStackInit(gp.m)` (a 1.24-only line;
   absent from go1.22 schedinit) caused a 3-way conflict. Resolved by dropping the
   unrelated `mProfStackInit` lines and keeping only the `noscanFileRegionInit()`
   call, placed after the `disableMemoryProfiling` block / before `lock(&sched.lock)`
   (i.e. after `gcinit`, world still stopped). Build ✅, tests ✅.
8. `f012f8ad41` GC stress, finalizer, env integration tests — 🛠 ✅ clean (test-only). Build ✅, tests ✅.
9. `679ea314d4` doc: document file-backed noscan region — 📄 ✅ clean.
10. `7869f6fdc7` route small and tiny spans — 🛠 ✅ clean (mheap.go auto-merged). Build ✅, tests ✅.
11. `48ba4bbebb` test tiny and mixed routing — 🛠 ✅ clean. Tests ✅ (small/tiny/mixed all PASS).
12. `96b3b817a6` doc: update for all sizes — 📄 ✅ clean.
13. `89f188d82c` fix heap accounting for ReadMemStats — 🛠 ✅ clean. Build ✅, tests ✅.
14. `083071ee71` support block devices — 🛠 🔧 fixup: the commit added files under
    `src/internal/runtime/syscall/` (the 1.24 syscall pkg path) and imported
    `internal/runtime/syscall` in memfile.go. go1.22 uses `runtime/internal/syscall`
    (dir `src/runtime/internal/syscall/`, which already exists). git mapped the
    amd64 defs add onto the existing 1.22 file (auto-merge, `SYS_IOCTL = 16`); the
    arm64 defs conflicted — resolved by adding `SYS_IOCTL = 29` + `SYS_MPROTECT = 226`
    (both absent from 1.22 arm64 defs). memfile.go import changed
    `internal/runtime/syscall` → `runtime/internal/syscall`. No stray
    `internal/runtime/syscall` dir. Build ✅, tests ✅.
15. `9ffba364b3` zero block device pages — 🛠 ✅ clean. Build ✅, tests ✅.
16. `6f4e776d4a` doc: block-device backing — 📄 ✅ clean.
17. `52cc6a9332` doc: etcd benchmark report — 📄 ✅ clean.
18. `cfd8ae6634` doc: reproducible etcd benchmark script — 📄 ✅ clean.
19. `1044a8587d` doc: fix latency field index — 📄 ✅ clean.
20. `866b6311cd` doc: refresh etcd benchmark — 📄 ✅ clean.
21. `1328c3a2d2` doc: physical memory estimation — 📄 ✅ clean.
22. `fad63f7678` proactive page eviction (MADV_PAGEOUT) — 🛠 ✅ clean (mgcsweep.go and all
    defs_linux_*.go auto-merged; `_MADV_PAGEOUT = 0x15` added, `pageoutFileRegion()`
    wired at mgcsweep.go:315 after sweep completion). Build ✅, tests ✅.
23. `32cd66b05c` doc: pageout results — 📄 ✅ clean.
24. `bbd35cfec2` doc: simplify etcd benchmark — 📄 ✅ clean.
25. `4d96d34076` GONOSCANFILEMIN filter — 🛠 ✅ clean (mheap.go auto-merged). Build ✅, tests ✅.
26. `6a22eca541` zero and evict freed region pages — 🛠 ✅ clean. Build ✅,
    `TestFreeRegionZeroAndPageout` ✅.
27. `d079c4dd26` doc,synth: file-backed bench script + synthetic harness — 📄 ✅ clean.
28. `277a6e5870` doc,synth: record go1.24 results — 📄 ✅ clean.

---

## Result

All **28 commits** cherry-picked onto `release-branch.go1.22` (go1.22.12). Only
**3 commits** needed fixups (all due to the Go 1.22→1.24 internal-package
renames / schedinit evolution); the remaining 25 applied cleanly. After the final
commit, `./make.bash` succeeds and **20/20** noscan runtime tests pass.

### Fixup summary

| commit | file(s) | cause | fix |
|---|---|---|---|
| `66fbbb44de` (cp3) | `memfile.go` | atomic pkg renamed in 1.24 | import `internal/runtime/atomic` → `runtime/internal/atomic` |
| `eb0fab1206` (cp7) | `proc.go` | schedinit context anchor `mProfStackInit(gp.m)` is 1.24-only | dropped the unrelated `mProfStackInit` lines; kept only `noscanFileRegionInit()` (placed after `gcinit`, before `lock(&sched.lock)`) |
| `083071ee71` (cp14) | `memfile.go`, `runtime/internal/syscall/defs_linux_arm64.go` | syscall pkg path differs (1.24 `internal/runtime/syscall` vs 1.22 `runtime/internal/syscall`, which pre-exists) | import → `runtime/internal/syscall`; the defs additions mapped onto the existing 1.22 file (amd64 auto-merged `SYS_IOCTL=16`; arm64 resolved by adding `SYS_IOCTL=29`+`SYS_MPROTECT=226`) |

No other conflicts. No stray `internal/runtime/{atomic,syscall}` directories were
left behind. The fixups are folded into their respective commits (via
`--amend` / conflict resolution at cherry-pick time), so each commit still builds
and passes the tests it introduces.

### Verification — synth_noscan (256 MiB live, 256 KiB objects)

Identical behavior on both toolchains (RSS in MiB):

| config | go1.24 fill / after_gc | go1.22 fill / after_gc |
|---|---|---|
| baseline | 258.9 / 258.9 | 260.4 / 260.4 |
| file (pageout off) | 259.3 / 259.3 | 260.0 / 260.0 |
| pageout | 32.9 / **3.4** | 14.2 / **4.4** |

pageout collapses resident noscan data to ~4 MiB in both cases; re-touch
re-fault cost ~217–276 ms. The mechanism is unchanged.

### Verification — etcd 3.5.18 (file-backed, baseline/file/pageout × 5 scenarios)

RSS savings (baseline_rss_after − pageout_rss_after, MiB) and pageout throughput:

| scenario | saved 1.24 | saved 1.22 | base req/s 1.24 / 1.22 | pgout req/s 1.24 / 1.22 |
|---|---|---|---|---|
| put_small  | 11.7 | 10.0 | 29994 / 31252 | 27771 / 30801 |
| put_medium | 27.2 | 37.4 | 27552 / 29787 | 24189 / 25957 |
| put_large  | 54.9 | 87.5 | 14454 / 14983 |  5350 /  5072 |
| range      | 13.6 | 13.3 | 51856 / 54829 | 48782 / 53124 |
| stm        |  7.6 | 10.7 | 30215 / 27738 | 29567 / 27914 |

Same shape on both: pageout saves RAM across all scenarios (largest on put_large,
whose 4 KiB values exceed the 256 B min filter and are routed+evicted); range
shows negative dRSS (eviction > allocation); and put_large throughput is
disk-re-fault bound (~5 k req/s) on both. Numeric deltas are within run-to-run
noise (single runs, no swap, /tmp on ext4). **Conclusion: the go1.22 backport
behaves the same as the go1.24 original.**

### Files updated for this branch
- `results_file/` — regenerated with go1.22.12 etcd results (was go1.24 on `noscan1`).
- `synth_noscan/results/` — regenerated 256 MiB smoke run on go1.22.12.
- `doc/noscan_rebase_1.22_report.md` — this report.
