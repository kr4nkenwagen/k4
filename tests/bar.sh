#!/bin/sh
# Bar tests (./build.sh test runs them): the fixture modules in tests/bar/ through k4 --bar
# --dump, with workspaces from a file; a click must run the module's command with its position.
set -u
cd "$(dirname "$0")/bar" || exit 2
K4=${K4:-../../k4}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
log="$tmp/clicks"
printf 'B\theight=26\nM\tmenu\tleft\ttext\tMENU\t0\taccent\techo "menu x=$K4_BAR_X w=$K4_BAR_WIDTH out=$K4_BAR_OUTPUT" >> %s\t-\t-\t-\t-\nM\tws\tleft\tworkspaces\t-\t0\t-\t-\t-\t-\t-\t-\nM\tclock\tcenter\tclock\tCLOCK|ALT\t0\t-\t-\t-\t-\t-\t-\nM\tbat\tright\texec\techo "{\\"text\\":\\"9%%\\",\\"class\\":\\"critical\\"}"\t30\tgreen\t-\t-\t-\t-\t-\nM\tgone\tright\texec\techo ""\t30\t-\t-\t-\t-\t-\t-\nM\tvol\tright\texec\tprintf \"one\\\\ntwo\\\\n\"\t0\tmagenta\t-\t-\t-\t-\t-\n' "$log" > "$tmp/spec"
pass=0 fail=0
check() {  # check NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi; }
run() { K4_BAR_WORKSPACES=workspaces.json "$K4" --bar --output eDP-1 --dump -w 1000 "$@" < "$tmp/spec" 2>&1; }
out=$(run)
check "workspaces of this output only; urgent marked" "left: [MENU] [1 2* 3!]" "$(printf '%s\n' "$out" | sed -n 1p)"
check "clock" "center: [CLOCK]" "$(printf '%s\n' "$out" | sed -n 2p)"
check "classes; empty hidden; a follower's latest line" "right: [9% (critical)] [two]" "$(printf '%s\n' "$out" | sed -n 3p)"
run --keys "<rclick:500,10>" >/dev/null
check "right click: the clock's other format" "center: [ALT]" "$(run --keys "<rclick:500,10>" | sed -n 2p)"
run --keys "<click:20,10>" >/dev/null; sleep 0.3
check "a click runs the command, told where" "menu x=N w=1000 out=eDP-1" "$(sed 's/x=[0-9][0-9]*/x=N/' "$log" 2>/dev/null)"
# the design's strip: k4's fields, the clock's date, 1–5 on a single output, open while a click runs
printf 'B\theight=26\tposition=bottom\nM\tws\tleft\tworkspaces\t-\t0\t-\t-\t-\t-\t-\t-\nM\tclk\tcenter\tclock\tT1;D1|T2;D2\t0\t-\t-\t-\t-\t-\t-\nM\tvol\tright\texec\techo "{\\"icon\\":\\"I\\",\\"text\\":\\"62%%\\",\\"text2\\":\\"x\\",\\"level\\":40}"\t30\t-\tsleep 2\t-\t-\t-\t-\nM\tbat\tright\texec\techo "{\\"battery\\":9,\\"text\\":\\"9%%\\",\\"class\\":\\"critical\\"}"\t30\t-\t-\t-\t-\t-\t-\nM\tmenu\tright\ticon\tG\t0\taccent\t-\t-\t-\t-\t-\tpx=9\n' > "$tmp/spec2"
run2() { K4_BAR_WORKSPACES=one-output.json "$K4" --bar --output eDP-1 --dump -w 1000 "$@" < "$tmp/spec2" 2>&1; }
out=$(run2)
check "one output: 1–5 always there, empty ones marked" "left: [1 2:web* 3_ 4_ 5_ 7]" "$(printf '%s\n' "$out" | sed -n 1p)"
check "clock: time and date" "center: [T1 · D1]" "$(printf '%s\n' "$out" | sed -n 2p)"
check "icon, level, text2, battery glyph, an icon module" "right: [I lvl:40 62% · x] [bat:9 9% (critical)] [G]" "$(printf '%s\n' "$out" | sed -n 3p)"
check "middle click: UTC for a moment" "center: [T1 · UTC]" "$(run2 --keys "<mclick:500,13>" | sed -n 2p)"
check "a left click's command keeps the module open (bottom bar)" "right: [I lvl:40 62% · x open] [bat:9 9% (critical)] [G]" "$(run2 --keys "<click:880,13>" | sed -n 3p)"
echo "bar tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
