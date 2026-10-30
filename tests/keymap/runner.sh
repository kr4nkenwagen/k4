#!/bin/sh
# k4-keymap act, in tests: the keyboard says it is on layer 2 (or, with KM_NOLIVE, why it is not live)
case "$1" in watch) if [ -n "$KM_NOLIVE" ]; then printf "nolive\t%s\n" "$KM_NOLIVE"; else printf "layer\t2\n"; fi ;; *) echo "($*)" ;; esac
