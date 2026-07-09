#!/bin/bash
#
# setup_zram.sh — one-time zram device setup for synth_noscan (and the etcd
# benchmark). Run as root:  sudo ./setup_zram.sh [SIZE]
#
# Creates /dev/zram0 as a raw block device (NOT swap) with zstd compression,
# sized to SIZE (default 2G), and makes it + its sysfs controls usable by a
# non-root process so run.sh can reset/resize it between configs.
#
# Requires a kernel with CONFIG_ZRAM (+ CONFIG_ZSMALLOC). Check with:
#   zcat /proc/config.gz | grep -iE 'CONFIG_ZRAM|CONFIG_ZSMALLOC'
# If absent, this script fails at modprobe and you must rebuild/replace the
# kernel (this machine's 6.1.44-cix vendor kernel has neither).
#
set -euo pipefail
DEV=zram0
SIZE="${1:-2G}"

to_bytes() {
  local s="$1" num suf mul=1
  num=$(printf '%s' "$s" | sed 's/[^0-9].*//')
  suf=$(printf '%s' "$s" | sed 's/^[0-9]*//' | tr '[:upper:]' '[:lower:]')
  case "$suf" in
    ""|b)         mul=1 ;;
    k|kb|kib)     mul=1024 ;;
    m|mb|mib)     mul=$((1024*1024)) ;;
    g|gb|gib)     mul=$((1024*1024*1024)) ;;
    *) echo "setup_zram: bad size suffix '$suf' in '$s'" >&2; exit 2 ;;
  esac
  echo $(( num * mul ))
}

modprobe zram num_devices=1
# reset clears comp_algorithm, so set it while disksize == 0, then arm disksize.
[[ -e /sys/block/$DEV/disksize ]] && echo 1 > /sys/block/$DEV/reset 2>/dev/null || true
echo zstd > /sys/block/$DEV/comp_algorithm
echo "$(to_bytes "$SIZE")" > /sys/block/$DEV/disksize
chmod 0666 /dev/$DEV
# allow a non-root run.sh to reset/resize between configs
chmod 0666 /sys/block/$DEV/reset /sys/block/$DEV/disksize 2>/dev/null || true

echo "$DEV ready: disksize=$(to_bytes "$SIZE") bytes ($SIZE)  comp=$(cat /sys/block/$DEV/comp_algorithm)  dev=/dev/$DEV"
echo "Now run:  FILE=/dev/$DEV TOTAL=<=$SIZE ./run.sh"
