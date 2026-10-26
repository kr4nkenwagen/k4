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
check "workspaces of this output only" "left: [MENU] [1 2* 3]" "$(printf '%s\n' "$out" | sed -n 1p)"
check "clock" "center: [CLOCK]" "$(printf '%s\n' "$out" | sed -n 2p)"
check "classes; empty hidden; a follower's latest line" "right: [9% (critical)] [two]" "$(printf '%s\n' "$out" | sed -n 3p)"
run --keys "<rclick:500,10>" >/dev/null
check "right click: the clock's other format" "center: [ALT]" "$(run --keys "<rclick:500,10>" | sed -n 2p)"
run --keys "<click:20,10>" >/dev/null; sleep 0.3
check "a click runs the command, told where" "menu x=N w=1000 out=eDP-1" "$(sed 's/x=[0-9][0-9]*/x=N/' "$log" 2>/dev/null)"
echo "bar tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
