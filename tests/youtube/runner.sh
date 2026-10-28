#!/bin/sh
# k4-youtube act, in tests: play and jump close the window, the rest say what they did
case "$1" in play|jump) echo "Playing"; echo k4:close ;; *) echo "($*)" ;; esac
