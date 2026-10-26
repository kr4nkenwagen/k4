#!/bin/sh
# The fixture tree's R command: logs what it ran (with K4_INPUT / K4_VALUE) and answers
# like a real script would, directives included.
echo "run $1${K4_INPUT:+ input=$K4_INPUT}${K4_VALUE:+ value=$K4_VALUE}" >> "$K4_TEST_LOG"
case "$1" in
  connect-open) echo "Wi-Fi  Connected to Cafe" ;;
  connect-secure) printf 'k4:input\tconnect-pw\tPassword for Home\tWPA2 network\tpassword\n' ;;
  connect-pw) echo "Wi-Fi  Connected to Home" ;;
  search) printf 'Search  done\nk4:page\tResults\tfor %s\tprintf "A\\tpkg-a\\tpkg-a\\tapt\\t\\tstay\\nA\\tpkg-b\\tpkg-b\\tapt\\t\\tstay\\n"\n' "$K4_INPUT" ;;
  pkg-a) printf 'Installed  pkg-a\nk4:back\n' ;;
  close) echo k4:close ;;
  *) echo "Ran  $1" ;;
esac
