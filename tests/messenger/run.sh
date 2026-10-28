#!/bin/sh
# The Messenger fixture's runner: what k4-messenger act answers, without a bridge.
case "$1" in
  search) printf 'k4:person\t101\tAnna Berg\nk4:person\t102\tAnna Lind\nk4:noreload\n2 on Messenger\n' ;;
  start) printf 'k4:open\t!new-%s\n%s · say hi\n' "$2" "$3" ;;
  *) echo "($*)" ;;
esac
