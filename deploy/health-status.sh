#!/usr/bin/env bash
# Writes public/status.txt (server disk, memory, load, last GitHub fetch) for
# the hourly "Server check" workflow on GitHub, which alerts when a value is
# out of range or the file stops updating. Called by pull-deploy.sh every
# 2 minutes as the orangiraffe user; reads only /proc and df.
set -euo pipefail
DIR=/opt/orangiraffe
OUT=$DIR/public/status.txt

disk=$(df -P / | awk 'NR==2 { sub("%", "", $5); print $5 }')
mem=$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf "%d", (t - a) * 100 / t }' /proc/meminfo)
load=$(cut -d' ' -f1 /proc/loadavg)
fetch=$(stat -c %Y "$DIR/.last-fetch" 2>/dev/null || echo 0)

{
  echo "updated=$(date +%s)"
  echo "disk_used_pct=$disk"
  echo "mem_used_pct=$mem"
  echo "load1=$load"
  echo "last_fetch=$fetch"
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
