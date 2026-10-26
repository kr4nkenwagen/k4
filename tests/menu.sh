#!/bin/sh
# Menu regression tests (./build.sh test runs them): each line of tests/menu/cases.txt opens
# the fixture tree with k4 --menu --dump, presses its keys, and compares what k4 shows (or
# prints on Enter) plus what the fixture runner was asked to run with
# tests/menu/expected/NAME.txt. COMPACT=1 in the env field opens it as a bar popup (--compact). Text, not pixels: fonts differ between machines.
#   tests/menu.sh            run them
#   UPDATE=1 tests/menu.sh   write the expected files from the current behaviour
set -u
cd "$(dirname "$0")/menu" || exit 2
K4=${K4:-../../k4}
DIR=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sed "s|@DIR@|$DIR|" tree.tsv > "$tmp/tree.tsv"
pass=0 fail=0
while IFS='	' read -r name open keys env; do
  case "$name" in ''|'#'*) continue ;; esac
  [ "$open" = - ] && open=""; [ "$keys" = - ] && keys=""; [ "${env:-}" = - ] && env=""
  log="$tmp/$name.log"; : > "$log"
  popup=""; case "|${env:-}|" in *"|COMPACT=1|"*) popup="--compact --popup 600,80,1280,center" ;; esac   # a bar popup
  # shellcheck disable=SC2086
  out=$(env K4_TEST_LOG="$log" K4_TEST_DIR="$DIR" K4_NOW=2026-10-26T10:09 $(printf '%s' "${env:-}" | tr '|' ' ') "$K4" --menu --dump --theme /dev/null \
        ${open:+--open "$open"} ${keys:+--keys "$keys"} $popup < "$tmp/tree.tsv" 2>&1; echo "exit $?")
  got=$(printf '%s\n' "$out"; sed 's/^/log: /' "$log")
  if [ -n "${UPDATE:-}" ]; then printf '%s\n' "$got" > "expected/$name.txt"; pass=$((pass + 1)); continue; fi
  if printf '%s\n' "$got" | diff -u "expected/$name.txt" - > "$tmp/diff"; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL $name"; sed 's/^/    /' "$tmp/diff"; fi
done < cases.txt
echo "menu tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
