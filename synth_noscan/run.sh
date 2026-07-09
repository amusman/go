#!/bin/bash
#
# run.sh — run synth_noscan under three configs and summarise the RSS deltas.
#
#   baseline  anonymous heap (no GONOSCANFILE)
#   file      GONOSCANFILE set, pageout OFF  (region resident)
#   pageout   GONOSCANFILE set, pageout ON   (cold data evicted to the file)
#
# Usage:
#   ./run.sh [TOTAL [OBJ]]
#   TOTAL=512MiB OBJ=64KiB ./run.sh
#
# Defaults: TOTAL=1GiB OBJ=256KiB. The region is sized to TOTAL.
#
set -euo pipefail

# --- config (overridable via env) ---
GOROOT="${GOROOT:-/home/orangepi/ws/go2}"
TOTAL="${TOTAL:-1GiB}"
OBJ="${OBJ:-256KiB}"
REGION="${REGION:-$TOTAL}"
FILE="${FILE:-/tmp/noscan_synth.bin}"
SETTLE="${SETTLE:-1500ms}"
OUT="${OUT:-./results}"

# Paths are relative to this script's directory.
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
PROG="$HERE/synth_noscan"
mkdir -p "$OUT"

export PATH="$GOROOT/bin:$PATH"
export GOROOT="$GOROOT"
export GOTOOLCHAIN=local
export CGO_ENABLED=0

# --- build once ---
echo "[build] $(go version)"
go build -trimpath -o "$PROG" .

run_cfg() {
	local label=$1; shift
	echo
	echo "================= $label ================="
	rm -f "$FILE"
	env "$@" "$PROG" -total "$TOTAL" -obj "$OBJ" -settle "$SETTLE" 2>&1 | tee "$OUT/$label.txt"
	# Report actual on-disk size of the backing file after the run.
	if [[ -e "$FILE" ]]; then
		sync
		printf "file_disk_MiB=%s\n" "$(du -m "$FILE" | awk '{print $1}')"
	else
		printf "file_disk_MiB=0\n"
	fi
}

run_cfg baseline
run_cfg file     GONOSCANFILE="$FILE" GONOSCANFILESIZE="$REGION" GONOSCANPAGEOUT=0
run_cfg pageout  GONOSCANFILE="$FILE" GONOSCANFILESIZE="$REGION"

rm -f "$FILE"

# --- summary ---
echo
echo "================= SUMMARY ================="
# Pull key phase RSS (rss_MiB = column 3) out of each config's table.
get_phase() { awk -v p="$1" '$1==p{print $3}' "$OUT/$2.txt" 2>/dev/null; }
get_retouch() { awk '$1=="retouch_refault"{print $2}' "$OUT/$1.txt" 2>/dev/null; }

printf "%-10s %14s %14s %14s %14s\n" \
	"config" "fill_live_MiB" "after_gc_MiB" "saved_vs_base" "retouch_dur"
printf '%*s\n' 66 "" | tr ' ' '-'
base_gc=$(get_phase after_gc_settle baseline)
for cfg in baseline file pageout; do
	fl=$(get_phase fill_live "$cfg")
	gc=$(get_phase after_gc_settle "$cfg")
	rt=$(get_retouch "$cfg")
	saved=$(awk -v b="$base_gc" -v g="$gc" 'BEGIN{printf "%.1f", b-g}')
	printf "%-10s %14s %14s %14s %14s\n" "$cfg" "${fl:-N/A}" "${gc:-N/A}" \
		"$([ "$cfg" = baseline ] && echo '-' || echo "${saved:-N/A}")" "${rt:--}"
done

echo
echo "(saved_vs_base = baseline.after_gc - <cfg>.after_gc, positive = less RAM)"
echo "Results in: $OUT/"
