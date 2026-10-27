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
check "tray: needs you, on the bar, in the tray" "tray 12 apps|* Discord · needs you · 3 unread|  Steam · needs you|  Nextcloud · on the bar" "$(tr | head -4 | paste -sd'|')"
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
ss() { "$K4" --ssh --dump "$@" < ../ssh/data.txt 2>&1; }
check "ssh: hosts grouped, pinned first" "ssh connect · 6 hosts · sshd on|* homelab · PINNED|  prod-web · CONFIG · PROD" "$(ss | head -3 | paste -sd'|')"
check "ssh: typing filters" "* bastion · CONFIG" "$(ss --keys "bast" | sed -n 2p)"
check "ssh: user@host is a new host" "* root@10.1.2.3 · TYPED" "$(ss --keys "root@10.1.2.3" | sed -n 2p)"
check "ssh: enter checks the host step by step" "band step|toast (check pi)" "$(ss --keys "<down><down><down><enter>" | tail -2 | paste -sd'|')"
check "ssh: a host that is down is not connected to" "toast 192.168.1.171 isn’t answering on 192.168.1.171:22 · try anyway with ⇧↵" "$(ss --keys "<down><down><down><down><down><enter>" | tail -1)"
check "ssh: ^F asks the forward, enter runs it" "toast (forward homelab 5432:db:5432)" "$(ss --keys "<ctrl-f>5432:db:5432<enter>" | tail -1)"
check "ssh: password login asks first" "* Password login (asking)|toast (pass on)" "$( (ss --open host --keys "<down><down><down><enter>" | grep asking; ss --open host --keys "<down><down><down><enter>y" | tail -1) | paste -sd"|")"
check "ssh: a session ends after y" "toast (end pts/3)" "$(ss --open host --keys "<right><del>y" | tail -1)"
check "ssh: keys, a adds to the agent" "toast (agent-add id_rsa_work)" "$(ss --open keys --keys "<down><down>a" | tail -1)"
check "ssh: Tab walks the pages" "ssh host · 6 hosts · sshd on" "$(ss --keys "<tab>" | head -1)"
# the count tag (chat badges): a module's "badge", the tray's unread column, the service's counts
printf 'B\theight=26\nM\tdc\tright\texec\techo "{\\"icon\\":\\"D\\",\\"badge\\":3,\\"badge_tone\\":\\"red\\"}"\t30\t-\t-\t-\t-\t-\t-\nM\tsl\tright\texec\techo "{\\"icon\\":\\"S\\",\\"badge\\":120}"\t30\t-\t-\t-\t-\t-\t-\nM\tnone\tright\texec\techo "{\\"icon\\":\\"N\\",\\"badge\\":0}"\t30\t-\t-\t-\t-\t-\t-\n' > "$tmp/spec3"
check "badge: a count tag with its tone; 0 none" "right: [D badge:3/red] [S badge:120] [N]" "$("$K4" --bar --dump -w 1000 < "$tmp/spec3" 2>&1 | sed -n 3p)"
check "tray: the unread count on an app" "* Discord · needs you · 3 unread" "$("$K4" --tray --dump < ../tray/apps.txt 2>&1 | sed -n 2p)"
# Passwords: the store from a file; a stand-in runner answers (tests/pass/runner.sh)
pa() { "$K4" --pass --dump "$@" 2>&1; }
pr() { (cat ../pass/store.txt; printf 'R\tsh ../pass/runner.sh\n') | pa "$@"; }
check "pass: actions, git, folders" "* New entry · name, then password (^N)|  [GIT] 2 ahead · 1 behind · origin git@github.com:jonfelix/pass.git|  [EMAIL/] 2 entries" "$(pa < ../pass/store.txt | grep 'New entry\|GIT\|EMAIL' | paste -sd'|')"
check "pass: typing filters, the match marked" "  [WEB/] 1 entry|* [hetz]ner · 2 m ago" "$(pa --keys "hetz" < ../pass/store.txt | tail -2 | paste -sd'|')"
check "pass: enter opens an entry, its fields from the runner" "* Copy password / •••••••••••••••••••••••••••••••• · 32 chars (↵)|  Copy username / jon@example.com (⇧↵)" "$(pr --keys "hub<enter>" | sed -n 2,3p | paste -sd'|')"
check "pass: enter copies; the footer counts down" "copied password" "$(pr --keys "hub<enter><enter>" | grep '^copied')"
check "pass: locked asks the passphrase here" "pass Unlock ok locked · 7 entries · “hub” · field •••••" "$(LOCKED=1 pr --keys "hub<enter><enter>right" | head -1)"
check "pass: a wrong passphrase says so and stays" "toast Wrong passphrase" "$(LOCKED=1 pr --keys "hub<enter><enter>wrong<enter>" | grep '^toast')"
check "pass: ^G generates and copies" "copied new password" "$(pr --keys "<ctrl-g>" | grep '^copied')"
check "pass: ^N names, then the password goes in K4_INPUT" "toast Saved shop/ikea (password hunter2)" "$(pr --keys "<ctrl-n>shop/ikea<enter>hunter2<enter>" | grep '^toast')"
check "pass: delete asks y / n" "* Delete web/github? y / n · removes it and commits (^D)" "$(pr --keys "hub<enter><ctrl-d>" | grep Delete)"
# Keyring, Media, Drives, Snapshots: data from files, no runner (actions say what they would run)
kr() { "$K4" --keyring --dump "$@" < ../keyring/secrets.txt 2>&1; }
check "keyring: groups, the one in use" "keyring unlocked · 4 saved|* WIFI Home-5G · WPA3 · saved 3 w ago · used now · in use" "$(kr | head -2 | paste -sd'|')"
check "keyring: Del asks, y forgets" "* VPN Office · saved 1 mo ago · forget? y / n|toast (forget vpn)" "$( (kr --keys "<down><down><del>" | grep forget; kr --keys "<down><down><del>y" | grep toast) | paste -sd'|')"
check "keyring: locked, Unlock closes and says so" "unlock" "$(printf 'S\t1\n' | "$K4" --keyring --dump --keys "<enter>" 2>&1)"
md() { "$K4" --media --dump "$@" 2>&1; }
check "media: now playing, the players" "media Playing · Teardrop — Massive Attack · Mezzanine|* Spotify · Playing · Teardrop" "$(md < ../media/players.txt | sed -n '1p;3p' | paste -sd'|')"
check "media: space, seek, track, volume, Tab" "(toggle org.mpris.MediaPlayer2.spotify)|(seek org.mpris.MediaPlayer2.spotify +5)|(next org.mpris.MediaPlayer2.spotify)|(volume org.mpris.MediaPlayer2.spotify 85)|(pick org.mpris.MediaPlayer2.firefox.instance_1_9)" "$(for k in " " "<right>" "<shift-right>" "<up>" "<tab>"; do md --keys "$k" < ../media/players.txt | grep '^toast' | cut -c7-; done | paste -sd'|')"
check "media: a live stream can't seek" "toast A live stream can’t seek" "$(md --keys "<right>" < ../media/live.txt | grep '^toast')"
dr() { "$K4" --drives --dump "$@" < ../drives/drives.txt 2>&1; }
check "drives: each card and its state" "* USB STICK · mounted · /run/media/kr4nk/STICK · 24 of 64 GB|  SSD Backup · busy · /run/media/kr4nk/Backup · 712 of 1000 GB" "$(dr | sed -n 2,3p | paste -sd'|')"
check "drives: m e y and enter" "(unmount /dev/sdb1)|(eject /dev/sdb1)|(copy /dev/sdb1)|(open /dev/sdb1)" "$(for k in m e y "<enter>"; do dr --keys "$k" | grep '^toast' | cut -c7-; done | paste -sd'|')"
check "drives: busy: enter closes them and ejects" "toast (force /dev/sdc1)" "$(dr --keys "<down><enter>" | grep '^toast')"
check "drives: an encrypted one takes its passphrase in the card" "toast (unlock /dev/sde1)" "$(dr --keys "<down><down><down>secret<enter>" | grep '^toast')"
sn() { "$K4" --snap --dump "$@" 2>&1; }
check "snap: the system first, then newest first" "* now|  #48 today 14:02 · post · pacman -Syu · 14 packages" "$(sn < ../snap/list.txt | sed -n 2,3p | paste -sd'|')"
check "snap: n takes one, c compares, r and Del ask" "(create)|(compare 48)|panel Restore|panel Delete" "$( (sn --keys "n" < ../snap/list.txt | grep '^toast' | cut -c7-; sn --keys "<down>c" < ../snap/list.txt | grep '^toast' | cut -c7-; sn --keys "<down>r" < ../snap/list.txt | head -1 | sed 's/.*· //'; sn --keys "<down><del>" < ../snap/list.txt | head -1 | sed 's/.*· //') | paste -sd'|')"
check "snap: deleting a post takes its pre" "toast (delete 48 47)" "$(sn --keys "<down><del>y" < ../snap/list.txt | grep '^toast')"
check "snap: without permission, what fixes it" "snap noperm · 0 snapshots · panel None|* Allow my user to use snapper" "$(sn < ../snap/noperm.txt | head -2 | paste -sd'|')"
rt() { "$K4" --router --dump "$@" < ../router/data.txt 2>&1; }
check "router: overview by default" "router overview · ok" "$(rt | head -1)"
check "router: Tab walks the pages" "router system · ok" "$(rt --keys "<tab>" | head -1)"
check "router: clients, newest first, tagged" "* pixel-8 192.168.1.142 NEW|  elin-macbook 192.168.1.31" "$(rt --open clients | sed -n 2,3p | paste -sd'|')"
check "router: typing filters the clients" "* esp-kitchen 192.168.1.77" "$(rt --open clients --keys "esp" | sed -n 2p)"
check "router: enter copies the IP" "toast (copy 192.168.1.31 192.168.1.31 · elin-macbook)" "$(rt --open clients --keys "<down><enter>" | tail -1)"
check "router: ^R asks, y reboots" "band reboot|toast (reboot)" "$( (rt --keys "<ctrl-r>" | grep band; rt --keys "<ctrl-r>y" | tail -1) | paste -sd'|')"
check "router: the radio this machine is on asks first" "band radiooff|toast (radio radio1 off)" "$( (rt --open wireless --keys "<down><enter>" | grep band; rt --open wireless --keys "<down><enter>y" | tail -1) | paste -sd'|')"
check "router: another radio turns off at once" "toast (radio radio0 off)" "$(rt --open wireless --keys "<enter>" | tail -1)"
check "router: no password takes the page, enter saves" "router overview · nopass · block nopass|toast (password)" "$( (sed 's/^G\tok/G\tnopass/' ../router/data.txt | "$K4" --router --dump 2>&1; sed 's/^G\tok/G\tnopass/' ../router/data.txt | "$K4" --router --dump --keys "secret<enter>" 2>&1 | tail -1) | paste -sd'|')"
check "router: unreachable, r retries" "toast (retry)" "$(sed 's/^G\tok/G\tunreach/' ../router/data.txt | "$K4" --router --dump --keys "r" 2>&1 | tail -1)"
# Bus departures: data from a file at a pinned clock (K4_BUS_NOW), no runner
bu() { K4_BUS_NOW=1793100000 "$K4" --bus --dump "$@" 2>&1; }
check "bus: soonest first; now, late, train, cancelled with the next one, timetable" "* 3 Teleborg · 4 min · Läge B|  1 Hov · 9 min · +3 late · Läge A|  KT Kalmar C · 11 min · Spår 2|  4 Araby · cancelled · next: 4 at 14:30 · Läge C|  7 Sandsbro · 17 min · timetable · Läge D" "$(bu < ../bus/departures.txt | sed -n 2,6p | paste -sd'|')"
check "bus: g groups by platform" "bus ok · Departures · Växjö Resecentrum · grouped|  [Läge B]" "$(bu --keys "g" < ../bus/departures.txt | head -2 | paste -sd'|')"
check "bus: enter sets a reminder; a cancelled one says what runs" "toast (remind 3 Teleborg 1793100240)|toast Line 4 at 14:15 is cancelled · next 4 at 14:30" "$( (bu --keys "<enter>" < ../bus/departures.txt | grep '^toast'; bu --keys "<down><down><down><enter>" < ../bus/departures.txt | grep '^toast') | paste -sd'|')"
check "bus: nothing in the hour names the one after" "empty · next line 7 at 15:18" "$(bu < ../bus/empty.txt | tail -1)"
check "bus: s picks a stop, the recent ones first" "bus ok · Pick · Växjö Resecentrum|* Växjö Resecentrum · recent" "$(bu --keys "s" < ../bus/departures.txt | head -2 | paste -sd'|')"
check "bus: typing searches, enter uses the stop" "toast (search res)|toast (pick 740002 Växjö Storgatan)" "$( (bu --keys "sres" < ../bus/departures.txt | grep '^toast'; bu --keys "s<down><enter>" < ../bus/departures.txt | grep '^toast') | paste -sd'|')"
check "bus: no key asks for one, enter checks it" "bus nokey · Key · |toast (key)" "$(bu --keys "abc<enter>" < ../bus/nokey.txt | sed -n '1p;$p' | paste -sd'|')"
printf 'B\theight=26\nM\tbus\tright\texec\techo "{\\"icon\\":\\"B\\",\\"box\\":\\"3\\",\\"text\\":\\"Teleborg\\",\\"text2\\":\\"4 min\\",\\"text2_bold\\":true}"\t30\t-\t-\t-\t-\t-\tslim\n' > "$tmp/spec4"
check "bar: a box (the bus line) with the text" "right: [B Teleborg · 4 min box:3]" "$("$K4" --bar --dump -w 1600 < "$tmp/spec4" 2>&1 | sed -n 3p)"
ds() { "$K4" --displays --dump "$@" < ../displays/two.txt 2>&1; }
check "displays: the screens, the external one picked" "  eDP-1 0,0 1440x900|* DP-1 1440,0 2560x1440" "$(ds | sed -n 2,3p | paste -sd'|')"
check "displays: dropped left of the laptop, it snaps to its edge, centred" "* DP-1 -2560,-270 2560x1440" "$(ds --keys "<press:493,270><move:120,250><release:120,250>" | sed -n 3p)"
check "displays: dropped on the laptop, it moves to the nearest free edge" "* DP-1 -560,900 2560x1440" "$(ds --keys "<press:493,270><move:280,250><release:280,250>" | sed -n 3p)"
check "displays: enter applies, the top left at 0,0" "toast (apply eDP-1 2560 270 DP-1 0 0)" "$(ds --keys "<press:493,270><move:120,250><release:120,250><enter>" | tail -1)"
check "displays: arrows nudge, r puts them back" "* DP-1 1440,0 2560x1440" "$(ds --keys "<right><down>r" | sed -n 3p)"
echo "bar tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
