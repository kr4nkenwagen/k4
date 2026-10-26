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
# the clock: a meeting from the calendar replaces the date (10 min before, and while it runs)
now=$(date +%s)
printf '%d\t%d\tReview\tmeet.google.com/x\n' $((now + 300)) $((now + 3600)) > "$tmp/soon.tsv"
printf '%d\t%d\tStandup\t\n' $((now - 60)) $((now + 600)) > "$tmp/now.tsv"
clock() { printf 'M\tclk\tcenter\tclock\tT1;D1\t0\t-\t-\t-\t-\t-\t-\tnext=%s\n' "$1" | "$K4" --bar --dump -w 1000 2>&1 | sed -n 2p; }
check "clock: a meeting within 10 min" "center: [T1 · Review in 5 min]" "$(clock "$tmp/soon.tsv")"
check "clock: a meeting now" "center: [T1 · Standup · now]" "$(clock "$tmp/now.tsv")"
# hovering a workspace: the preview of its windows (K4_BAR_CLIENTS / K4_BAR_MONITORS stand in for Hyprland)
prev=$(K4_BAR_CLIENTS=clients.json K4_BAR_MONITORS=monitors.json run2 --keys "<move:50,13>" | grep '^preview')
check "workspace preview: its windows, focused and floating marked, web apps named" "preview 2 web · eDP-1: [>_ ghostty] [Fi firefox focused] [Di discord float]" "$prev"
check "no preview off the workspaces" "" "$(K4_BAR_CLIENTS=clients.json K4_BAR_MONITORS=monitors.json run2 --keys "<move:50,13><move:900,13>" | grep '^preview')"
# the overview (Super+Tab): every workspace, 1–8 always, its windows; keys move, Tab steps in, typing finds
ov() { K4_BAR_WORKSPACES=one-output.json K4_BAR_CLIENTS=clients.json K4_BAR_MONITORS=monitors.json "$K4" --overview --dump "$@" 2>&1; }
check "overview: 1–8, the focused one picked" "overview 8 workspaces|  1 Workspace 1:|* 2 web: [ghostty] [firefox] [discord]|  3 Workspace 3:" "$(ov | head -4 | paste -sd'|')"
check "overview: → picks the next card" "* 3 Workspace 3:" "$(ov --keys "<right>" | grep '^\*')"
check "overview: Tab steps into the windows" "* 2 web: [ghostty] [>firefox] [discord]" "$(ov --keys "<tab><tab>" | grep '^\*')"
check "overview: typing finds windows" "overview \"fire\" · 1 match|* 2 web: [ghostty] [firefox hit] [discord]" "$(ov --keys "fire" | grep '^overview\|^\*' | paste -sd'|')"
check "overview: Esc clears the search, then closes" "exit 1" "$(ov --keys "fire<esc><esc>"; echo "exit $?")"
# the system menu (Super+Esc): tiles from a file; k4 prints the picked id ("id!" forced)
pw() { "$K4" --power --dump "$@" < ../power/tiles.txt 2>&1; }
check "power: the tiles, Lock picked, Hibernate off" "* L Lock|  H Hibernate (off: no swap)" "$(pw | grep '^\* \|off:' | paste -sd'|')"
check "power: a letter runs a tile" "suspend" "$(pw --keys "s")"
check "power: reboot asks, No is picked" "ask Reboot now? · Yes · on no" "$(pw --keys "r" | grep '^ask')"
check "power: y says yes" "reboot" "$(pw --keys "ry")"
check "power: n cancels" "toast Cancelled" "$(pw --keys "rn" | grep '^toast')"
check "power: an inhibitor makes it Force" "poweroff!" "$(printf 'I\tapt (upgrading)\n' | cat ../power/tiles.txt - | "$K4" --power --dump --keys "p<left><enter>" 2>&1)"
check "power: an unavailable tile says why" "toast No swap big enough for 16 GB of RAM. Set it up in Setup › Power." "$(pw --keys "h" | grep '^toast')"
check "power: Esc closes" "exit 1" "$(pw --keys "<esc>"; echo "exit $?")"
# notifications: the popups from fixture notes, the centre from a fixture list (no service, no bus)
nd() { K4_NOTIFY_FIXTURE=1 "$K4" --notifyd --dump "$@" < ../notify/notes.txt 2>&1; }
check "notify: critical first, one card an app, +N more" "popup System · Battery critically low · 5%|popup Mail · 3 new newsletters|popup Slack · Jonas Lind +1|+2 more" "$(nd | grep '^popup\|more' | paste -sd'|')"
nc() { K4_NOTIFY_LIST=../notify/list.txt "$K4" --notify-center --dump "$@" 2>&1; }
check "centre: grouped by app, newest first" "centre 9 · dnd off|*   System · Battery critically low · 5%|    Calendar · Standup in 5 min|  [Slack 3]" "$(nc | head -4 | paste -sd'|')"
check "centre: space folds a group" "* [Slack 3 folded]|    Slack · Anna Berg · #platform +2" "$(nc --keys "<down><down> " | grep -A1 '^\* \[Slack' | paste -sd'|')"
check "centre: enter runs the first action" "toast Hibernate · Battery critically low · 5%  (act 9 hibernate)" "$(nc --keys "<enter>" | grep '^toast')"
check "centre: a button's letter runs it" "toast Power saver · Battery critically low · 5%  (act 9 saver)" "$(nc --keys "p" | grep '^toast')"
check "centre: x dismisses, d do not disturb" "toast Dismissed  (dismiss 8)|toast Do not disturb on  (dnd toggle)" "$( (nc --keys "<down>x"; nc --keys "d") | grep '^toast' | paste -sd'|')"
# the clipboard window: entries from a file, no runner (pin and delete only say what they would run)
cl() { K4_CLIP_NOW=1793020000 "$K4" --clip --dump "$@" < ../clip/entries.txt 2>&1; }
check "clip: pinned first, then newest" "clip All · 10 of 10|* ◆ jon.felix@kestrel.dev · text|  ◆ Host kestrel-build · block|  git rebase -i HEAD~3 · text" "$(cl | head -4 | paste -sd'|')"
check "clip: typing searches labels and text" "clip All · 1 of 10|* def parse_quick(s: str) -> Event: · block" "$(cl --keys "QUICK.match" | head -2 | paste -sd'|')"
check "clip: Tab filters by kind" "clip Blocks · 3 of 10" "$(cl --keys "<tab><tab>" | head -1)"
check "clip: enter pastes, shift-enter copies" "paste	3|copy	3" "$( (cl --keys "<down><down><enter>"; cl --keys "<down><down><shift-enter>") | paste -sd'|')"
check "clip: ctrl-enter on text pastes plain, on a block opens it" "plain	3|extra	2" "$( (cl --keys "<down><down><ctrl-enter>"; cl --keys "<down><ctrl-enter>") | paste -sd'|')"
check "clip: alt-2 pastes the second unpinned one" "paste	5" "$(cl --keys "<alt-2>")"
check "clip: ctrl-p pins in place" "toast (pin 1)" "$(cl --keys "<ctrl-p>" | grep '^toast')"
check "clip: Esc clears the search, then closes" "exit 1" "$(cl --keys "x<esc><esc>"; echo "exit $?")"
# the tray popup: apps from a file, a menu from K4_TRAY_MENU, no runner (actions say what they would run)
tr() { "$K4" --tray --dump "$@" < ../tray/apps.txt 2>&1; }
check "tray: needs you, on the bar, in the tray" "tray 12 apps|* Discord · needs you|  Steam · needs you|  Nextcloud · on the bar" "$(tr | head -4 | paste -sd'|')"
check "tray: arrows move by line, four tiles a line" "* Tailscale · in the tray" "$(tr --keys "<down><down><down>" | grep '^\*')"
check "tray: typing filters names and status" "tray 12 apps|* Nextcloud · on the bar|  Syncthing · in the tray" "$(tr --keys "sync" | paste -sd'|')"
check "tray: space opens the app" "toast (open discord)" "$(tr --keys " " | grep '^toast')"
check "tray: ctrl-p pins" "* Tailscale · on the bar|toast (pin tailscale)" "$(tr --keys "<down><down><down><ctrl-p>" | grep '^\*\|^toast' | paste -sd'|')"
check "tray: enter opens the app's menu, k4's rows last" "tray menu Nextcloud|* Open Nextcloud folder|  [IN K4]|  Show on the bar (switch on)" "$(K4_TRAY_MENU="$(cat ../tray/menu.txt)" tr --keys "<down><down><enter>" | grep 'menu\|^\*\|IN K4\|Show on' | paste -sd'|')"
check "tray: a submenu and back" "tray menu Nextcloud · Recent activity" "$(K4_TRAY_MENU="$(cat ../tray/menu.txt)" tr --keys "<down><down><enter><down><down><down><enter>" | head -1 | sed 's/ › / · /')"
check "tray: a menu row runs" "toast (event nextcloud 2)" "$(K4_TRAY_MENU="$(cat ../tray/menu.txt)" tr --keys "<down><down><enter><down><enter>" | grep '^toast')"
# the System popup: the pages and the utilities (live numbers are not compared; no runner, no kills)
pf() { K4_PERF_NOKILL=1 "$K4" --perf --dump "$@" < ../perf/utils.txt 2>&1; }
check "perf: overview first, Tab and 1–3 switch pages" "perf overview|perf processes|perf utilities" "$( (pf | head -1; pf --keys "<tab>" | head -1; pf --keys "3" | head -1) | paste -sd'|')"
check "perf: processes sort by cpu, → memory" "sort cpu · 12 shown|sort mem · 12 shown" "$( (pf --keys "2" | sed -n 2p; pf --keys "2<right>" | sed -n 2p) | paste -sd'|')"
check "perf: utilities left column first" "* Free up space · Empty trash|  Free up space · Clear thumbnails|  Fix things · Restart audio" "$(pf --keys "3" | sed -n 2,4p | paste -sd'|')"
check "perf: a utility marked ask asks first" "* Free up space · Empty trash (asking)" "$(pf --keys "3<enter>" | sed -n 2p)"
check "perf: y runs it, n cancels" "toast (trash)|* Free up space · Empty trash" "$( (pf --keys "3<enter>y" | grep '^toast'; pf --keys "3<enter>n" | sed -n 2p) | paste -sd'|')"
check "perf: a step row moves its value" "toast (profile Performance)" "$(pf --keys "3<right><down><right>" | grep '^toast')"
# Send to (LocalSend): devices from a file, no service
sd() { K4_SEND_FIXTURE=1 "$K4" --send --dump "$@" < ../send/devices.txt 2>&1; }
check "send: the devices, the first picked" "send 3 FILES · files · 6 devices|* Jon’s Pixel 8" "$(sd | head -2 | paste -sd'|')"
check "send: space picks several, enter sends to all" "send 3 FILES · files · 6 devices · 2 picked|toast (send files to 2)" "$(sd --keys "<down> <down> <enter>" | grep '^send\|^toast' | paste -sd'|')"
check "send: a device not answering is not sent to" "toast iPad is not answering · pick another or scan again (r)" "$(sd --keys "<down><down><down><down><down><enter>" | grep '^toast')"
check "send: Tab closes to pick what is sent" "pick	folder" "$(sd --keys "<tab>")"
check "send: Esc clears picks, then closes" "exit 0" "$(sd --keys "<down> <esc><esc>" >/dev/null; echo "exit $?")"
echo "bar tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
