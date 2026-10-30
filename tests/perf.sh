#!/usr/bin/env bash
# How fast windows open: each window's data command (what k4 waits for) and k4's own start with a
# fixture (fonts, layout, the first frame as --dump), the median of 3 runs each, in ms.
#   tests/perf.sh            both tables      tests/perf.sh k4    only k4's start (no live data)
set -u
cd "$(dirname "$0")" || exit 2
K4=${K4:-../k4}
ms() { local s; s=$(date +%s%N); eval "$1" >/dev/null 2>&1; echo $(( ($(date +%s%N) - s) / 1000000 )); }
median() { local a b c; a=$(ms "$1"); b=$(ms "$1"); c=$(ms "$1"); printf '%s\n%s\n%s\n' "$a" "$b" "$c" | sort -n | sed -n 2p; }
row() { printf '  %-26s %6s ms\n' "$1" "$(median "$2")"; }

echo "k4's start (fixture, --dump)"
row "launcher (menu)" "$K4 --menu --dump < /dev/null"
row "clock" "$K4 --clock --dump < clock/world.txt"
row "wow" "$K4 --wow --dump < wow/roster.txt"
row "releases" "K4_NOW=2026-10-30T10:32 $K4 --releases --dump < releases/data.txt"
row "mail" "$K4 --mail --dump < mail/inbox.txt"
row "notifications" "K4_NOTIFY_FIXTURE=1 $K4 --notifyd --dump < notify/notes.txt"
[ "${1:-}" = k4 ] && exit 0

echo "data (live, what each window waits for)"
for w in clock wow releases messenger mail youtube claude bus keymap; do
  command -v "k4-$w" >/dev/null && row "k4-$w data" "k4-$w data"
done
for p in discord parcels events todo; do
  command -v "k4-$p" >/dev/null && row "k4-$p page" "k4-$p section"
done
row "launcher tree" "sway-menu k4-tree"
