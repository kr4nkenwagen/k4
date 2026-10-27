#!/bin/sh
# a stand-in for pass-menu's runner: what the Passwords window would hear back
case "$1" in
  fields) printf 'k4:field user jon@example.com\nk4:field url https://github.com\nk4:field otp 1\nk4:field len 32\nk4:field code 428913 20\n' ;;
  copy) [ -n "${LOCKED:-}" ] && { echo k4:locked; exit; }; printf 'k4:copied %s\n' "$3" ;;
  unlock) [ "$K4_INPUT" = right ] && printf 'Unlocked for 10 min\nk4:unlocked\n' || printf 'Wrong passphrase\nk4:tone red\nk4:noreload\n' ;;
  generate) printf 'k4:copied new password\nk4:secret v7#Qe9!pLr2\n' ;;
  insert) printf 'Saved %s (password %s)\nk4:list\n' "$2" "$K4_INPUT" ;;
  *) echo "ran $*" ;;
esac
