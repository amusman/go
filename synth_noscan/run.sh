#!/bin/bash
#
# run.sh — run synth_noscan under three configs and summarise the RSS deltas.
#
#   baseline  anonymous heap (no GONOSCANFILE)
#   file      GONOSCANFILE set, pageout OFF  (region resident)
#   pageout   GONOSCANFILE set, pageout ON   (cold data evicted to the backing store)
#
# Backing store: set FILE=. For a regular file (default) usage is measured with
# du. For a zram block device (e.g. FILE=/dev/zram0), usage is the compressed
# size from /sys/block/zram0/mm_stat and the device is reset+re-armed between
# runs so each config starts from a clean mm_stat. See setup_zram.sh.
#
# Usage:
#   ./run.sh [TOTAL [OBJ]]
#   TOTAL=512MiB OBJ=64KiB ./run.sh
#   FILE=/dev/zram0 TOTAL=1GiB ./run.sh        # zram-backed (run setup_zram.sh first)
#
# Defaults: TOTAL=1GiB OBJ=256KiB. The region is sized to TOTAL (so for zram,
# set the device disksize >= TOTAL via setup_zram.sh).
#
set -euo pipefail

# Paths are relative to this script's directory.
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# --- config (overridable via env) ---
GOROOT="${GOROOT:-$(cd "$HERE/.." && pwd)}"   # repo root (../bin/go after make.bash)
TOTAL="${TOTAL:-1GiB}"
OBJ="${OBJ:-256KiB}"
REGION="${REGION:-$TOTAL}"
FILE="${FILE:-/tmp/noscan_synth.bin}"
COMP="${COMP:-zstd}"          # zram comp_algorithm (ignored for regular files)
SETTLE="${SETTLE:-1500ms}"
OUT="${OUT:-./results}"
PROG="$HERE/synth_noscan"
IS_BLOCK=0; [[ -b "$FILE" ]] && IS_BLOCK=1
mkdir -p "$OUT"

if [[ ! -x "$GOROOT/bin/go" ]]; then
  echo "ERROR: $GOROOT/bin/go not found. Build the toolchain first, e.g.:" >&2
  echo "  cd \"$GOROOT/src\" && GOROOT_BOOTSTRAP=/path/to/go ./make.bash" >&2
  exit 1
fi

export PATH="$GOROOT/bin:$PATH"
export GOROOT="$GOROOT"
export GOTOOLCHAIN=local
export CGO_ENABLED=0

# Convert a size like 1GiB / 2G / 512 to bytes (zram disksize takes bytes only).
to_bytes() {
  local s="$1" num suf mul=1
  num=$(printf '%s' "$s" | sed 's/[^0-9].*//')
  suf=$(printf '%s' "$s" | sed 's/^[0-9]*//' | tr '[:upper:]' '[:lower:]')
  case "$suf" in
    ""|b)         mul=1 ;;
    k|kb|kib)     mul=1024 ;;
    m|mb|mib)     mul=$((1024*1024)) ;;
    g|gb|gib)     mul=$((1024*1024*1024)) ;;
    *) echo "to_bytes: unknown suffix '$suf' in '$s'" >&2 ;;
  esac
  echo $(( num * mul ))
}

# Reset the backing store between configs so each starts clean.
reset_backing() {
  if [[ "$IS_BLOCK" -eq 1 ]]; then
    local base="/sys/block/$(basename "$FILE")"
    # reset clears compressed pages AND comp_algorithm; re-arm both before disksize.
    if [[ -w "$base/reset" ]]; then
      echo 1 > "$base/reset"
      echo "$COMP" > "$base/comp_algorithm" 2>/dev/null || true
      echo "$(to_bytes "$REGION")" > "$base/disksize"
    else
      echo "WARN: $base/reset not writable — run as root, or re-run setup_zram.sh" >&2
    fi
  else
    rm -f "$FILE"
  fi
}

# Backing-store usage in MiB: zram mm_stat mem_used_total (compressed) for a
# block device, else actual on-disk blocks (du).
backing_mib() {
  if [[ "$IS_BLOCK" -eq 1 ]]; then
    awk '{print $3}' "/sys/block/$(basename "$FILE")/mm_stat" 2>/dev/null \
      | awk '{printf "%.1f", $1/1024/1024}'
  else
    [[ -e "$FILE" ]] && du -m "$FILE" | awk '{printf "%.1f", $1}' || echo 0.0
  fi
}

# --- build once ---
echo "[build] $(go version)   backing=$FILE $([[ $IS_BLOCK -eq 1 ]] && echo '(block device/zram)' || echo '(regular file)')"
go build -trimpath -o "$PROG" .

run_cfg() {
	local label=$1; shift
	echo
	echo "================= $label ================="
	reset_backing
	env "$@" "$PROG" -total "$TOTAL" -obj "$OBJ" -settle "$SETTLE" 2>&1 | tee "$OUT/$label.txt"
	sync
	printf 'backing_MiB=%s\n' "$(backing_mib)" | tee -a "$OUT/$label.txt"
}

run_cfg baseline
run_cfg file     GONOSCANFILE="$FILE" GONOSCANFILESIZE="$REGION" GONOSCANPAGEOUT=0
run_cfg pageout  GONOSCANFILE="$FILE" GONOSCANFILESIZE="$REGION"

# Final cleanup (only meaningful for the regular-file case).
[[ "$IS_BLOCK" -eq 0 ]] && rm -f "$FILE"

# --- summary ---
echo
echo "================= SUMMARY ================="
get_phase()   { awk -v p="$1" '$1==p{print $3}' "$OUT/$2.txt" 2>/dev/null; }
get_retouch() { awk '$1=="retouch_refault"{print $2}' "$OUT/$1.txt" 2>/dev/null; }
get_backing() { awk -F= '/^backing_MiB=/{print $2}' "$OUT/$1.txt" 2>/dev/null; }
total_mib=$(awk -v b="$(to_bytes "$TOTAL")" 'BEGIN{printf "%.1f", b/1024/1024}')

printf "%-10s %14s %14s %14s %14s %16s\n" \
	"config" "fill_live_MiB" "after_gc_MiB" "saved_vs_base" "retouch_dur" "backing_MiB"
printf '%*s\n' 86 "" | tr ' ' '-'
base_gc=$(get_phase after_gc_settle baseline)
for cfg in baseline file pageout; do
	fl=$(get_phase fill_live "$cfg")
	gc=$(get_phase after_gc_settle "$cfg")
	rt=$(get_retouch "$cfg")
	bk=$(get_backing "$cfg")
	saved=$(awk -v b="$base_gc" -v g="$gc" 'BEGIN{printf "%.1f", b-g}')
	printf "%-10s %14s %14s %14s %14s %16s\n" "$cfg" "${fl:-N/A}" "${gc:-N/A}" \
		"$([ "$cfg" = baseline ] && echo '-' || echo "${saved:-N/A}")" "${rt:--}" "${bk:-N/A}"
done

echo
echo "(saved_vs_base = baseline.after_gc - <cfg>.after_gc, positive = less RAM)"
echo "(backing_MiB = zram compressed size for /dev/zram*, else on-disk file size)"
if [[ "$IS_BLOCK" -eq 1 ]]; then
	pgbk=$(get_backing pageout)
	[[ -n "$pgbk" && "$pgbk" != "0.0" ]] && \
	  echo "pageout compression: $total_mib MiB -> ${pgbk} MiB  (~$(awk -v t="$total_mib" -v b="$pgbk" 'BEGIN{printf "%.1f", t/b}'):1)"
fi
echo "Results in: $OUT/"
