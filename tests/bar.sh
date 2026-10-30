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
# Messenger: conversations from a fixture (no runner: the actions say what they would run)
ms() { K4_MESSENGER_NOW=1793180000 "$K4" --messenger --dump "$@" 2>&1; }
check "messenger: unread first, opened at a chat: its messages, the line to write" "  CONVERSATIONS|  Anna Berg (2) · Lunch at 12?|  Family [3] (1) · Dinner on Sunday, bring the kids|  > you: Yes, working from home until 4|writing " "$( (ms < ../messenger/chats.txt | sed -n 2,4p; ms < ../messenger/chats.txt | grep -E '> you|^writing') | paste -sd'|')"
check "messenger: ↵ sends (shown at once); Esc goes to the list, ↓ ↵ opens the next" "  > you: hello there|toast (send !anna)|toast (open !fam)" "$( (ms --keys "hello there<enter>" < ../messenger/chats.txt | grep -E 'hello|^toast'; ms --keys "<esc><down><enter>" < ../messenger/chats.txt | grep '^toast') | paste -sd'|')"
check "messenger: typing in the list finds a chat by anyone in it" "find dad|* Family [3] (1) · Dinner on Sunday, bring the kids" "$(ms --keys "<esc>dad" < ../messenger/chats.txt | sed -n 2,3p | paste -sd'|')"
check "messenger: an unnamed group found by a member shows them first; 8 chats, then the older ones" "* Sofia Nyberg, Maja Holm, Anna Berg +1 [5] · See you Saturday|* Show 2 older chats|  Omar Said · [sticker]" "$( (ms --keys "<esc>sofia<down>" < ../messenger/ready.txt | grep '^\*'; ms --keys "<esc>$(printf '<down>%.0s' 1 2 3 4 5 6 7 8)" < ../messenger/ready.txt | grep '^\*'; ms --keys "<esc>$(printf '<down>%.0s' 1 2 3 4 5 6 7 8)<enter>" < ../messenger/ready.txt | tail -12 | grep 'Omar') | paste -sd'|')"
check "messenger: the encrypted chats waiting; a group's size" "waiting 15 encrypted|  Climbing club [9] (5) · Wall is booked" "$(ms < ../messenger/ready.txt | grep -E '^waiting|Climbing' | paste -sd'|')"
check "messenger: not set up, starting, not running: their cards; ↵ does what they say" "card Not_Set_Up|toast (setup)|card Starting|toast (unlock)|card Not_Running|toast (journal)" "$( (ms < ../messenger/setup.txt | grep '^card'; ms --keys "<enter>" < ../messenger/setup.txt | grep '^toast'; ms < ../messenger/starting.txt | grep '^card'; ms --keys "<enter>" < ../messenger/starting.txt | grep '^toast'; ms < ../messenger/down.txt | grep '^card'; ms --keys "l" < ../messenger/down.txt | grep '^toast') | paste -sd'|')"
touch ../messenger/run/k4-messenger-setup.log   # (a log older than 10 minutes is old news to the window)
check "messenger: a setup that stopped shows where (its log); ↵ runs it again, l shows the log" "card Setup · step 3 · failed: download failed (connection reset)|toast (setup)|toast (log)" "$( (XDG_RUNTIME_DIR=../messenger/run ms < ../messenger/setup.txt | grep '^card'; XDG_RUNTIME_DIR=../messenger/run ms --keys "<enter>" < ../messenger/setup.txt | grep '^toast'; XDG_RUNTIME_DIR=../messenger/run ms --keys "l" < ../messenger/setup.txt | grep '^toast') | paste -sd'|')"
check "messenger: log in: a pasted cURL is checked for the session (its cookies hidden), ↵ hands it over" "input curl 'https://www.messenger.com/' -H 'cookie: ••••••••••••••••' … · session found|toast (login)|input curl 'https://www.facebook.com/' -H 'cookie: ••••••••••••••••' … · no c_user|toast Paste a Messenger cURL first|toast (web)" "$( (K4_MESSENGER_CLIPBOARD="$(printf "curl 'https://www.messenger.com/' \\\\\n -H 'cookie: c_user=1; xs=2'")" ms --keys "<ctrl-v>" < ../messenger/login.txt | grep '^input'; K4_MESSENGER_CLIPBOARD="curl x -H 'cookie: c_user=1; xs=2'" ms --keys "<ctrl-v><enter>" < ../messenger/login.txt | grep '^toast'; K4_MESSENGER_CLIPBOARD="curl 'https://www.facebook.com/' -H 'cookie: datr=3'" ms --keys "<ctrl-v>" < ../messenger/login.txt | grep '^input'; K4_MESSENGER_CLIPBOARD="curl x -H 'datr=3'" ms --keys "<ctrl-v><enter>" < ../messenger/login.txt | grep '^toast'; ms --keys "o" < ../messenger/login.txt | grep '^toast') | paste -sd'|')"
check "messenger: logged out: a banner, read-only, ↵ the login card; not answering: ^R retries" "banner logged out|toast Log in again to send|card Login|banner not answering|toast (retry)" "$( (sed '1s/.*/S\trelogin\t3\tJon\tSession expired/' ../messenger/chats.txt | ms | grep '^banner'; sed '1s/.*/S\trelogin\t3\tJon\t/' ../messenger/chats.txt | ms --keys "hi<enter>" | grep '^toast'; sed '1s/.*/S\trelogin\t3\tJon\t/' ../messenger/chats.txt | ms --keys "<esc><enter>" | grep '^card'; sed '1s/.*/S\terror\t3\tJon\t/' ../messenger/chats.txt | ms | grep '^banner'; sed '1s/.*/S\terror\t3\tJon\t/' ../messenger/chats.txt | ms --keys "<ctrl-r>" | grep '^toast') | paste -sd'|')"
check "messenger: ^V pastes into the line to write" "writing see you at 12" "$(K4_MESSENGER_CLIPBOARD="see you at 12" ms --keys "<ctrl-v>" < ../messenger/chats.txt | grep '^writing')"
ml() { K4_MAIL_NOW=1793310000 "$K4" --mail --dump "$@" 2>&1; }
check "mail: the inbox (unread, count, star, clip); ↵ opens the picked thread" "* • Maja Lind, me (3) ★ · Saturday ride? — Great, Erik joins too|  Erik Svensson ⎘ · Photos from the trip — Here are the best ones|toast (open t1)" "$( (ml < ../mail/inbox.txt | grep -E '^\* •|Erik Svensson'; ml --keys "<enter>" < ../mail/inbox.txt | grep '^toast') | paste -sd'|')"
check "mail: typing searches: the list narrows at once (Gmail's is:unread too); ↵ with no match asks Gmail" "* • Maja Lind, me (3) ★ · Saturday ride? — Great, Erik joins too|  • Nordbank · Your October statement — Your statement is ready|empty|toast (search from:zed)" "$( (ml --keys "is:unread" < ../mail/inbox.txt | grep -E '^(\*|  •)'; ml --keys "from:zed<enter>" < ../mail/inbox.txt | grep -E '^toast|^empty') | paste -sd'|')"
check "mail: ^E archives, Del trashes, ^S stars the picked thread; ^Z undoes the archive" "toast (archive t1)|toast (trash t2)|toast (star t1)|toast (unarchive t1)" "$( (ml --keys "<ctrl-e>" < ../mail/inbox.txt; ml --keys "<down><del>" < ../mail/inbox.txt; ml --keys "<ctrl-s>" < ../mail/inbox.txt; ml --keys "<ctrl-e><ctrl-z>" < ../mail/inbox.txt) | grep '^toast' | paste -sd'|')"
check "mail: a thread: older messages folded, the newest open (its address), the quote behind a button" "  [folded] Maja Lind: Thinking of the north trails at 9, bring lights.|  Maja Lind <maja@example.com> → me cc Erik Svensson: Great, Erik joins too. Vi ses på lördag!|    quoted (folded)|    quoted: > Sounds good, I'll be there." "$( (ml < ../mail/thread.txt | grep -E '^  \[folded\] Maja|^  Maja Lind <|quoted'; ml --keys "<ctrl-q>" < ../mail/thread.txt | grep 'quoted:') | paste -sd'|')"
check "mail: typing in a thread replies (⇧↵ a new line), ↵ sends; ^⇧R replies to all; ^L the newest link" "toast (send reply t1)|reply all hey|toast (url https://example.com/route/12)" "$( (ml --keys "see you<shift-enter>at 9<enter>" < ../mail/thread.txt | grep '^toast'; ml --keys "<shift-ctrl-r>hey" < ../mail/thread.txt | grep '^reply'; ml --keys "<ctrl-l>" < ../mail/thread.txt | grep '^toast') | paste -sd'|')"
check "mail: the picked attachment; ↵ opens it" "    *attachment summit.jpg · 200 KB|toast (attachment m5 att1 summit.jpg)" "$(ml --keys "<right><enter>" < ../mail/attach.txt | grep -E 'toast|attachment' | paste -sd'|')"
check "mail: ^N the card: an address in To, a name looked up, ^↵ sends what it holds; ^A files; ^F forward" "card New mail · field 0|toast (who maja)|  To: a@b.se | Cc:  | Subject: Hi |  | Hello there|toast (send compose new )|toast (pick)|card Forward · t1 · field 0|toast (prefill forward t1)" "$( (ml --keys "<ctrl-n>" < ../mail/inbox.txt | grep '^card'; ml --keys "<ctrl-n>maja<enter>" < ../mail/inbox.txt | grep '^toast'; ml --keys "<ctrl-n>a@b.se<enter><tab><tab>Hi<enter>Hello there<ctrl-enter>" < ../mail/inbox.txt | grep -E '^toast|^  To'; ml --keys "<ctrl-n><ctrl-a>" < ../mail/inbox.txt | grep '^toast'; ml --keys "<ctrl-f>" < ../mail/inbox.txt | grep -E '^card|^toast') | paste -sd'|')"
check "mail: k4-mail window --compose TO: the card with them in To, at the subject" "card New mail · field 2|  To: erik@example.com | Cc:  | Subject: " "$(K4_MAIL_COMPOSE=erik@example.com ml < ../mail/inbox.txt | grep -E '^card|^  To' | paste -sd'|')"
check "mail: syncing (skeleton), the cards (signin: ? the how-to; no client: ^O the file), offline's banner" "skeleton|card connect|toast (connect)|card signin|toast (howto)|card noclient|toast (pickclient)|banner offline · 2 waiting" "$( (ml < ../mail/syncing.txt | grep skeleton; ml < ../mail/connect.txt | grep '^card'; ml --keys "<enter>" < ../mail/connect.txt | grep '^toast'; ml < ../mail/signin.txt | grep '^card'; ml --keys "?" < ../mail/signin.txt | grep '^toast'; ml < ../mail/noclient.txt | grep '^card'; ml --keys "<ctrl-o>" < ../mail/noclient.txt | grep '^toast'; ml < ../mail/offline.txt | grep '^banner') | paste -sd'|')"
check "mail: Tab picks a label; the popup: one pane (the open thread, Esc the list), Tab steps the dropdown" "toast (label Label_7)|mail ok · 1 unread · Inbox · popup Read|mail ok · 1 unread · Inbox · popup List|toast (label STARRED)" "$( (ml --keys "<tab><down><down><down><down><down><down><enter>" < ../mail/inbox.txt | grep '^toast'; ml --popup 600,80,1280,right < ../mail/thread.txt | head -1; ml --popup 600,80,1280,right --keys "<esc>" < ../mail/thread.txt | head -1; ml --popup 600,80,1280,right --keys "<tab>" < ../mail/inbox.txt | grep '^toast') | paste -sd'|')"
check "mail: Gmail's error as a banner; the API turned off: ↵ opens its page" "banner error · The Gmail API is off in your Google Cloud project · turn it on (↵ opens the page), wait a minute|toast (enableapi)" "$( (ml < ../mail/apioff.txt | grep '^banner'; ml --keys "<enter>" < ../mail/apioff.txt | grep '^toast') | paste -sd'|')"
ww() { K4_WOW_NOW=1793310000 "$K4" --wow --dump "$@" 2>&1; }
check "wow: the roster (gold, rested; max level without), the realm and token; ↵ unfolds lockouts, cooldowns, bags and professions" "wow ok · Chars · 2 characters · 450g 34s 68c · reset in 1 d 12 h|realm Silverpine UP queue|token 4210g 0s 0c|* Elowen 60 Mage · 412g 34s 56c|  Brakk 44 Warrior · 38g 0s 12c · rested 150%|    lockout Molten Core 7/10|    cooldown Transmute: Arcanite · ready|    bags 14 free of 80 · Alchemy 300 · Tailoring 285" "$( (ww < ../wow/roster.txt | grep -E '^wow|^realm|^token|Elowen|Brakk'; ww --keys "<enter>" < ../wow/roster.txt | grep -E 'lockout|cooldown|bags') | paste -sd'|')"
check "wow: addons: k4's first, then updates, then the rest; ^U updates all, ^Z undoes; a running game blocks both; typing filters" "  K4|* K4 Companion 2 · k4|  UPDATES · 1|  Details! Damage Meter 1.2 · wago → 1.3|  UP TO DATE|  Questie 9.1.0 · untracked|undo Questie 9.0.4 → 9.1.0|toast (update all)|toast (undo)|banner close WoW first|toast Close WoW first · updates wait until it quits|* find quest|  UP TO DATE|  Questie 9.1.0 · untracked" "$( (ww --keys "<tab>" < ../wow/roster.txt | grep -E '^  |^\* '; ww --keys "<tab>" < ../wow/roster.txt | grep '^undo'; ww --keys "<tab><ctrl-u>" < ../wow/roster.txt | grep '^toast'; ww --keys "<tab><ctrl-z>" < ../wow/roster.txt | grep '^toast'; sed 's/^S\t\(.*\)\t0\t1$/S\t\1\t1\t1/' ../wow/roster.txt | ww --keys "<tab><ctrl-u>" | grep -E '^banner|^toast'; ww --keys "<tab>quest" < ../wow/roster.txt | grep -E '^  [A-Z]|^\* ') | paste -sd'|')"
check "wow: addon search: ↵ searches both, hits install with ↵, a source without a key gets the key card (^V, ↵ keeps it)" "toast (search atlas)|keycard curseforge|  INSTALLED · 0|  FROM WAGO AND CURSEFORGE · 2|* Atlas Classic · wago · install|toast (add wago AbC12)|keycard curseforge (pasted)|toast (key curseforge)" "$( (ww --keys "<tab>atlas<enter>" < ../wow/roster.txt | grep '^toast'; K4_WOW_TAB=addons ww --keys "atlas<down>" < ../wow/search.txt | grep -E '^keycard|^  [IF]|^\* '; K4_WOW_TAB=addons ww --keys "atlas<down><enter>" < ../wow/search.txt | grep '^toast'; K4_WOW_TAB=addons K4_MESSENGER_CLIPBOARD=abc ww --keys "atlas<down><ctrl-v>" < ../wow/search.txt | grep '^keycard'; K4_WOW_TAB=addons K4_MESSENGER_CLIPBOARD=abc ww --keys "atlas<down><ctrl-v><enter>" < ../wow/search.txt | grep '^toast') | paste -sd'|')"
check "wow: raid nights: the weekly ones, typing adds one, Del removes, ↵ opens Calendar" "* fri 20:00 Molten Core · in 21 h 20 m|  sun 19:30 Onyxia · in 2 d 20 h|toast (raid add thu 20:00 bwl)|toast (raid remove 1)|toast (calendar)" "$( (ww --keys "<alt-3>" < ../wow/roster.txt | grep -E '^[* ] (fri|sun)'; ww --keys "<alt-3>thu 20:00 bwl<enter>" < ../wow/roster.txt | grep '^toast'; ww --keys "<alt-3><down><del>" < ../wow/roster.txt | grep '^toast'; ww --keys "<alt-3><enter>" < ../wow/roster.txt | grep '^toast') | paste -sd'|')"
check "wow: the cards: companion missing (a banner), no character (↵ plays), not installed (↵ Battle.net); ^P plays" "banner companion missing|card neverplayed|toast (play)|card notinstalled|toast (apps)|toast (play)" "$( (ww < ../wow/nocompanion.txt | grep '^banner'; ww < ../wow/nochars.txt | grep '^card'; ww --keys "<enter>" < ../wow/nochars.txt | grep '^toast'; ww < ../wow/missing.txt | grep '^card'; ww --keys "<enter>" < ../wow/missing.txt | grep '^toast'; ww --keys "<ctrl-p>" < ../wow/roster.txt | grep '^toast') | paste -sd'|')"
rl() { K4_NOW=2026-10-30T10:32 "$K4" --releases --dump "$@" 2>&1; }
check "releases: movies grouped by week (Swedish cinema date, Netflix for streaming), ★ ▶ cal marks; the detail's dates and trailers" "  NEXT WEEK|* Paper Harbour · Fri 6 Nov in 7 d · on Netflix · Comedy|  DECEMBER|  The Last Lighthouse · Fri 18 Dec in 49 d · in cinemas · Drama, Mystery ★ ▶2 cal|  date 2026-12-18 in cinemas|  * trailer Official Trailer|  trailer Teaser" "$( (rl < ../releases/data.txt | sed -n 3,6p; rl --keys "<down>" < ../releases/data.txt | grep -E '^  date 2026-12|trailer') | paste -sd'|')"
check "releases: ↵ plays the trailer, t the next, c the calendar, f follows, o the page; the Following tab; typing searches the tab's source" "toast (play movies 101 0)|toast (play movies 101 1)|toast (cal movies 102)|toast (follow tv 201)|toast (open books 401)|releases Following · 2|toast (search games ashfall)" "$( (rl --keys "<down><enter>" < ../releases/data.txt | grep '^toast'; rl --keys "<down>t" < ../releases/data.txt | grep '^toast'; rl --keys "c" < ../releases/data.txt | grep '^toast'; rl --keys "<alt-2>f" < ../releases/data.txt | grep '^toast'; rl --keys "<alt-4>o" < ../releases/data.txt | grep '^toast'; rl --keys "<alt-5>" < ../releases/data.txt | head -1; rl --keys "<alt-3>ashfall<enter>" < ../releases/data.txt | grep '^toast') | paste -sd'|')"
check "releases: a tab without its key: the card, the key pasted (hidden) and kept" "nokey movies|* field (hidden)|toast (key tmdb)" "$( (rl < ../releases/nokeys.txt | grep '^nokey'; K4_MESSENGER_CLIPBOARD=abc123 rl --keys "<ctrl-v>" < ../releases/nokeys.txt | grep 'field'; K4_MESSENGER_CLIPBOARD=abc123 rl --keys "<ctrl-v><enter>" < ../releases/nokeys.txt | grep '^toast') | paste -sd'|')"
check "releases: categories: the tab's genres, the most common first; ← → filters by one, a click too; books by Hardcover's genre tags" "categories *All · Comedy · Drama · Mystery|releases Movies · 1|* The Last Lighthouse · Fri 18 Dec in 49 d · in cinemas · Drama, Mystery ★ ▶2 cal|categories All · Comedy · Drama · *Mystery|categories *All · Fantasy · Literary" "$( (rl < ../releases/data.txt | grep '^categories'; rl --keys "<right><right>" < ../releases/data.txt | grep -E '^releases|^\* '; rl --keys "<left>" < ../releases/data.txt | grep '^categories'; rl --keys "<alt-4>" < ../releases/data.txt | grep '^categories') | paste -sd'|')"
check "releases: a list being fetched in the background: the window doesn't wait, says so, looks again" "releases Books · 0 · refreshing" "$(rl --keys "<alt-4>" < ../releases/refreshing_empty.txt | head -1)"
ck() { K4_CLOCK_NOW=1793352734 TZ=Europe/Stockholm "$K4" --clock --dump "$@" 2>&1; }
check "clock: world: here first, the time in each city, a DST change soon; ← → compares; ↵ copies a time; typing adds a city" "clock World · 10:32 · Fri 30 Oct|* Stockholm 10:32 · local|  New York 05:32 · −5 h · goes to −6 h on Sun 1 Nov|  Tokyo 18:32 · +8 h|compare +5 h|toast (event 15)|toast (copy London 09:32)|add Dubai|toast (city add Dubai)" "$( (ck < ../clock/world.txt | grep -E '^clock|Stockholm|New York|Tokyo'; ck --keys "<right><right><right><right><right>" < ../clock/world.txt | grep compare; ck --keys "<right><right><right><right><right><enter>" < ../clock/world.txt | grep '^toast'; ck --keys "<down><enter>" < ../clock/world.txt | grep '^toast'; ck --keys "du" < ../clock/world.txt | grep '^add'; ck --keys "du<enter>" < ../clock/world.txt | grep '^toast') | paste -sd'|')"
check "clock: timers: time left, running or paused; Space pauses, + a minute, Del removes; “1h30 bread” ↵ starts one; a chip too" "* 27:41 Bread · second rise · running|  1:12 Tea · running|  11:03 Focus · 25 min · paused|toast (timer toggle 1)|toast (timer plus 2 60)|toast (timer remove 3)|start 1:30:00 bread|toast (timer add 5400 bread)" "$( (K4_CLOCK_TAB=timers ck < ../clock/world.txt | grep -E '^[* ] [0-9]'; K4_CLOCK_TAB=timers ck --keys " " < ../clock/world.txt | grep '^toast'; K4_CLOCK_TAB=timers ck --keys "<down>+" < ../clock/world.txt | grep '^toast'; K4_CLOCK_TAB=timers ck --keys "<down><down><del>" < ../clock/world.txt | grep '^toast'; K4_CLOCK_TAB=timers ck --keys "1h30 bread" < ../clock/world.txt | grep '^start'; K4_CLOCK_TAB=timers ck --keys "1h30 bread<enter>" < ../clock/world.txt | grep '^toast') | paste -sd'|')"
check "clock: alarms: next ring or off; Space switches, “6:45 weekdays gym” ↵ sets one" "* 06:45 Wake up · 1111100 · in 2 d 20 h|  08:30 Weekend run · 0000011 · in 21 h 57 min|  22:30 Wind down · 1111111 · off|toast (alarm toggle 4)|set 06:45 weekdays gym|toast (alarm add 6 45 1111100 gym)" "$( (K4_CLOCK_TAB=alarms ck < ../clock/world.txt | grep -E 'Wake|Weekend|Wind'; K4_CLOCK_TAB=alarms ck --keys " " < ../clock/world.txt | grep '^toast'; K4_CLOCK_TAB=alarms ck --keys "6:45 weekdays gym" < ../clock/world.txt | grep '^set'; K4_CLOCK_TAB=alarms ck --keys "6:45 weekdays gym<enter>" < ../clock/world.txt | grep '^toast') | paste -sd'|')"
check "clock: ringing: a timer done (Esc stops, + one more minute), an alarm (s snoozes); the stopwatch: Space, l" "ringing timer Tea|toast (stop)|toast (more)|ringing alarm Call the garage|toast (snooze)|stopwatch 00:04:51.60 running · 4 laps|toast (watch toggle)|toast (watch lap)" "$( (K4_CLOCK_TAB=timers ck < ../clock/done.txt | grep '^ringing'; ck --keys "<esc>" < ../clock/done.txt | grep '^toast'; ck --keys "+" < ../clock/done.txt | grep '^toast'; ck < ../clock/ring.txt | grep '^ringing'; ck --keys "s" < ../clock/ring.txt | grep '^toast'; K4_CLOCK_TAB=watch ck < ../clock/world.txt | grep '^stopwatch'; K4_CLOCK_TAB=watch ck --keys " " < ../clock/world.txt | grep '^toast'; K4_CLOCK_TAB=watch ck --keys "l" < ../clock/world.txt | grep '^toast') | paste -sd'|')"
check "mail: several accounts: All inboxes (each row its account), ↵ opens an IMAP one, a section's folder" "  • Lina Ek · [home] Book for December — I vote for the short one this time|toast (open home:INBOX:812)|toast (label home:INBOX)" "$( (ml < ../mail/accounts.txt | grep 'Lina'; ml --keys "<down><enter>" < ../mail/accounts.txt | grep '^toast'; ml --keys "<tab><down><down><down><down><down><enter>" < ../mail/accounts.txt | grep '^toast') | paste -sd'|')"
check "mail: the card goes from the shown account (All inboxes: the first); ↑ From, → the next" "  From: gmail | To:  | Cc:  | Subject: |  From: home | To:  | Cc:  | Subject: " "$( (ml --keys "<ctrl-n>" < ../mail/accounts.txt | grep '^  From'; ml --keys "<ctrl-n><up><right>" < ../mail/accounts.txt | grep '^  From') | paste -sd'|')"
check "messenger: links open in the browser: a click (a wrapped one from either line, without the full stop after it), ^L the newest; plain text not" "toast (url https://example.com/bikes)|toast (url https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabcdefghijklmnopqrstuvwxyz0123456789&index=12)|toast (url https://www.example.org/route)|0" "$( (ms --keys "<click:490,341>" < ../messenger/links.txt | grep '^toast'; ms --keys "<click:480,408>" < ../messenger/links.txt | grep '^toast'; ms --keys "<ctrl-l>" < ../messenger/links.txt | grep '^toast'; ms --keys "<click:420,486>" < ../messenger/links.txt | grep -c '^toast') | paste -sd'|')"
msm() { sed "s|@DIR@|$(cd ../messenger && pwd)|" ../messenger/media.txt | ms "$@"; }   # photos and videos: their previews
check "messenger: pictures shown; ^O opens the newest, a click the one clicked" "  > you: [video] (picture /photo.png)|toast (media \$5)|toast (media \$4)" "$( (msm | grep '> you: \[video' | sed 's| /[^ ]*/photo| /photo|'; msm --keys "<ctrl-o>" | grep '^toast'; msm --keys "<click:500,180>" | grep '^toast') | paste -sd'|')"
check "messenger: ^N searches people, ↓ ↵ opens the chat with one (a stand-in runner)" "* person Anna Berg|  person Anna Lind|open !new-102|toast Anna Lind · say hi" "$( (ms --keys "<ctrl-n>anna<enter>" < ../messenger/chats-run.txt | grep 'person'; ms --keys "<ctrl-n>anna<enter><down><enter>" < ../messenger/chats-run.txt | grep -E '^(open|toast)') | paste -sd'|')"
# The OSD (the KOsd board): one box, its fields as given; a bad field is left out, the hold defaults
osd() { "$K4" --osd "$1" --dump 2>&1 | head -1; }
check "osd: volume, muted, past 100" "osd · label Volume · sub Speakers · built-in · bar 62 · val 62%|osd · label Muted · bar 62 · bar_off 1 · val — · edge red|osd · label Volume · bar 140 · val 140% · edge yellow" "$( (osd "icon=󰕾|label=Volume|sub=Speakers · built-in|bar=62|val=62%"; osd "label=Muted|bar=62|bar_off=1|val=—|edge=red"; osd "label=Volume|bar=140|val=140%|edge=yellow|junk") | paste -sd'|')"
check "osd: mic chips, keyboard steps, media glyph and progress" "osd · label Microphone muted · chips MUTED:red:fill · edge red|osd · label Keyboard light · steps 1/2 · val Low|osd · label Teardrop · line Massive Attack · Spotify · glyph play · prog 254 · hold 2500" "$( (osd "label=Microphone muted|chips=MUTED:red:fill|edge=red"; osd "label=Keyboard light|steps=1/2|val=Low"; osd "label=Teardrop|line=Massive Attack · Spotify|glyph=play|prog=254|hold=2500") | paste -sd'|')"
# YouTube: results, the queue and what plays from fixtures (no runner: the actions say what they would run)
yt() { local f="$1"; shift; sed "s|@DIR@|$(cd ../youtube && pwd)|" "../youtube/$f.txt" | K4_YOUTUBE_NOW=1793180000 "$K4" --youtube --dump "$@" 2>&1; }
check "youtube: the results, four across, the grid picked; a thumbnail or not; live; what plays" "tab Results 9|* Rainy night jazz for focus · Café Sounds · 1:30:00|  Live: harbour webcam · Port Cam · LIVE · nothumb|now ▶ Rainy night jazz for focus · 12:34 / 1:30:00 · PiP · TOP LEFT" "$( (yt results | grep -E '^tab|Rainy|Live:'; yt playing | grep '^now') | paste -sd'|')"
check "youtube: arrows pick, ↵ plays, a queues, o opens on youtube.com, d only in the queue" "* Synth pads, the easy way · Patch Notes · 10:12 · nothumb|toast (play a6)|toast (queue a6)|toast (browser a2)|toast d removes from the Queue tab" "$( (yt results --keys "<down><right>" | grep '^\*'; yt results --keys "<down><right><enter>" | grep '^toast'; yt results --keys "<down><right>a" | grep '^toast'; yt results --keys "<right>o" | grep '^toast'; yt results --keys "d" | grep '^toast') | paste -sd'|')"
check "youtube: typing anywhere searches; ↵ sends it; ↑ from the top row goes to the field" "find lofi||toast (search lofi beats)|find |" "$( (yt results --keys "lofi" | grep '^find'; yt results --keys "lofi beats<enter>" | grep '^toast'; yt results --keys "<up>" | grep '^find') | paste -sd'|')"
check "youtube: the queue lists what comes next; ↵ plays it now, d takes it out" "tab Queue 1|* Ten knots every climber should know · Rope Lab · 14:02 · nothumb|toast (jump 1)|toast (remove 1)" "$( (yt playing --keys "<tab>" | grep -E '^tab|^\*'; yt playing --keys "<tab><enter>" | grep '^toast'; yt playing --keys "<tab>d" | grep '^toast') | paste -sd'|')"
check "youtube: history: how far, ↵ resumes, ^⌫ clears" "  Sourdough without a scale · Crumb · 41%|  Learn Odin in one hour · Ginger Codes · watched · nothumb|toast (play a7 resume)|toast (forget)" "$( (yt playing --keys "<alt-3>" | grep -E 'Sourdough|Learn Odin' | sed 's/^\*/ /'; yt playing --keys "<alt-3><enter>" | grep '^toast'; yt playing --keys "<alt-3><ctrl-bs>" | grep '^toast') | paste -sd'|')"
check "youtube: space pauses, n next, p back, y the player" "toast (pause)|toast (next)|toast (prev)|toast (pip)" "$( (yt playing --keys " " | grep '^toast'; yt playing --keys "n" | grep '^toast'; yt playing --keys "p" | grep '^toast'; yt playing --keys "y" | grep '^toast') | paste -sd'|')"
check "youtube: nothing searched: your home page (↵ plays, ^R fetches it again); signed out: continue watching (↵ resumes)" "tab Results 5 · home|toast (play h1)|toast (home)|tab Results 1 · continue watching · home signedout|toast (play a7 resume)" "$( (yt home | grep '^tab'; yt home --keys "<down><enter>" | grep '^toast'; yt home --keys "<ctrl-r>" | grep '^toast'; yt signedout | grep '^tab'; yt signedout --keys "<down><enter>" | grep '^toast') | paste -sd'|')"
check "youtube: the home page scrolls without end: its last row (keys or the wheel) asks for more; the first row does not" "toast (home-more)|toast (home-more)|" "$( (yt home --keys "<down><down>" | grep '^toast'; yt home --keys "<wheel:1><wheel:1>" | grep '^toast'; yt home --keys "<down><right>" | grep -c '^toast' | sed 's/^0$//') | paste -sd'|')"
ytr() { (sed "s|@DIR@|$(cd ../youtube && pwd)|" ../youtube/results.txt; printf 'R\tsh ../youtube/runner.sh\n') | "$K4" --youtube --dump "$@" 2>&1; echo "exit $?"; }
check "youtube: a video started (↵, or the queue's) closes the window; queueing keeps it" "exit 0|toast (queue a1)" "$( (ytr --keys "<enter>" | tail -2 | paste -sd' ' | sed 's/^ *//'; ytr --keys "a" | grep '^toast') | paste -sd'|')"
check "youtube: a search that names a channel: it first; ↵ opens its videos, a says so; in its videos Esc goes back to the search" "* [channel] Rope Lab · @RopeLab · 350000 subscribers|toast (channel UCabc)|toast A channel: ↵ opens its videos, a queues one of them|channel Rope Lab|toast (back)" "$( (yt channel | grep '^\*'; yt channel --keys "<enter>" | grep '^toast'; yt channel --keys "a" | grep '^toast'; yt chanview | grep '^channel'; yt chanview --keys "<up><esc>" | grep '^toast') | paste -sd'|')"
check "youtube: Esc in an empty field after a search: back to the home page; nothing found; offline (^R again)" "toast (clear)|card NoResults|card Offline|toast (search focus music)" "$( (yt results --keys "<up><esc>" | grep '^toast'; yt empty | grep '^card'; yt error | grep '^card'; yt error --keys "<ctrl-r>" | grep '^toast') | paste -sd'|')"
check "youtube: missing (↵ installs), installing" "card Missing · yt-dlp missing · mpv 0.41.0|toast (install)|card Installing · yt-dlp missing · mpv 0.41.0" "$( (yt missing | grep '^card'; yt missing --keys "<enter>" | grep '^toast'; yt installing | grep '^card') | paste -sd'|')"
# Keymap: a Corne's QMK layout (a fixture), the keyboard's layer from a stand-in stream
km() { "$K4" --keymap --dump "$@" < ../keymap/corne.txt 2>&1; }
# Jellyfin: the same window over k4-jellyfin's data (jellyfin.py's output from the fake server in tests/jellyfin/api)
jf() { local f="$1"; shift; K4_YOUTUBE_NOW=1793180000 "$K4" --jellyfin --dump "$@" < "../jellyfin/$f.txt" 2>&1; }
jfr() { local f="$1"; shift; (cat "../jellyfin/$f.txt"; printf 'R\tsh ../youtube/runner.sh\n') | K4_YOUTUBE_NOW=1793180000 "$K4" --jellyfin --dump "$@" 2>&1; echo "exit $?"; }
check "jellyfin: home is continue watching, next up, recently added, with where each stopped" "jellyfin ok|tab Results 4 · home|  The Quiet Harbour · 2024 · Movie · 1:50:00 · [resume] · at 36% · nothumb|  Northern Static · Echoes · S1 · E4 · 47:00 · [nextup] · nothumb" "$(jf home | sed -n '1p;3p;4p;6p' | paste -sd'|')"
check "jellyfin: a search puts the show first (its episodes open), then movies and episodes" "* [show] Northern Static · 2025 · 5 unwatched|  Static Bloom · 2023 · Movie · 1:41:00 · nothumb" "$(jf results | sed -n 4,5p | paste -sd'|')"
check "jellyfin: ↵ on a show opens its episodes" "toast (channel a1b2c3d4e5f60718293a4b5c6d7e8f90)" "$(jfr results --keys "<enter>" | grep '^toast' | head -1)"
check "jellyfin: a show's episodes, by season and number" "channel Northern Static|* Static · S1 · E1 · 48:00 · nothumb" "$(jf show | sed -n '3p;5p' | paste -sd'|')"
check "jellyfin: what plays (the shared corner player) is marked on its tile" "  The Quiet Harbour · 2024 · Movie · 1:50:00 · playing · [resume] · at 36% · nothumb|now ▶ The Quiet Harbour · 41:40 / 1:50:00 · PiP · TOP LEFT" "$(jf playing | sed -n '4p;$p' | paste -sd'|')"
check "jellyfin: ↵ plays and the window goes (the corner player takes over)" "exit 0" "$(jfr results --keys "<right><enter>" | tail -1)"
kml() { (cat ../keymap/corne.txt; printf 'R\tsh ../keymap/runner.sh\n') | "$K4" --keymap --dump "$@" 2>&1; }
check "keymap: the layers (a missing one marked), the base's keys: mods held, layer keys, none" "layers *0 Base | 1 Layer 1 | 2 Layer 2 | 3 Layer 3 (missing)|Esc A/Ctrl S/Shift D/Super F/Alt G" "$( (km | grep '^layers'; km | grep '^keys' | cut -d' ' -f16-21) | paste -sd'|')"
check "keymap: → and a number show another layer; transparent keys show the layer they are reached from" "layers 0 Base | *1 Layer 1 | 2 Layer 2 | 3 Layer 3 (missing)|▽L1 ▽L2" "$( (km --keys "<right>" | grep '^layers'; km --keys "2" | grep '^keys' | tr ' ' '\n' | grep '▽' | paste -sd' ') | paste -sd'|')"
check "keymap: picking another layer stays on it (f follows the keyboard again); a missing layer's key; opened on a layer" "picked|following|[L3|layers 0 Base | *1 Layer 1 | 2 Layer 2 | 3 Layer 3 (missing)" "$( (kml --keys "0" | grep -E '^(following|picked)'; kml --keys "0f" | grep -E '^(following|picked)'; km --keys "1" | grep '^keys' | tr ' ' '\n' | grep -F '[L3'; K4_KEYMAP_LAYER=1 km | grep '^layers') | paste -sd'|')"
check "keymap: the peek opens on the layer pressed, follows the next one, keeps it after the key is let go" "layers 0 Base | *1 Layer 1 | 2 Layer 2 | 3 Layer 3 (missing)|layers 0 Base | 1 Layer 1 | *2 Layer 2 (live) | 3 Layer 3 (missing)" "$( (K4_KEYMAP_LAYER=1 km --peek | grep '^layers'; K4_KEYMAP_LAYER=1 kml --peek | grep '^layers') | paste -sd'|')"
check "keymap: live: the keyboard's layer shown and marked; not live: why" "layers 0 Base | 1 Layer 1 | *2 Layer 2 (live) | 3 Layer 3 (missing)|not live · no layer report in this firmware|toast (pull)" "$( (kml | grep '^layers'; KM_NOLIVE="no raw hid" kml | grep '^not live'; kml --keys "r" | grep '^toast') | paste -sd'|')"
nf() { K4_NOTIFY_FIXTURE=1 "$K4" --notifyd --dump "$@" < ../notify/focus.txt 2>&1; }   # with a warn card, a reply, then focus
printf '#!/bin/sh\necho "$1 $2 [$K4_INPUT]" >> "$(dirname "$0")/reply.log"\n' > "$tmp/reply-cmd"; chmod +x "$tmp/reply-cmd"
check "notify: a posted card's inline reply runs its command with the text" "reply 1 [sure, 12?]" "$(printf 'post\t0\tMessenger\tAnna\tLunch?\t1\t-1\t-1\t\t\t\tinline-reply:Reply\t%s\nfocus\n' "$tmp/reply-cmd" | K4_NOTIFY_FIXTURE=1 "$K4" --notifyd --dump --keys "rsure, 12?<enter>" >/dev/null 2>&1; for i in 1 2 3 4 5 6; do [ -s "$tmp/reply.log" ] && break; sleep 0.2; done; cat "$tmp/reply.log")"
ni() { cat ../notify/immersive.txt - | K4_NOTIFY_FIXTURE=1 "$K4" --notifyd --dump "$@" 2>&1; }
check "notify: wait (a ringing alarm: the edge lit), warn (a timer done), done (a realm back up: the tag green)" "popup Clock · 10:30 · Call the garage (wait)|popup WoW · Silverpine is back up (done)|popup Clock · Tea · done +1 (warn)" "$( (head -1 ../notify/kinds.txt | K4_NOTIFY_FIXTURE=1 "$K4" --notifyd --dump 2>&1 | grep '^popup'; K4_NOTIFY_FIXTURE=1 "$K4" --notifyd --dump < ../notify/kinds.txt 2>&1 | grep '^popup') | paste -sd'|')"
check "notify: a parcel's pickup code shown large on its card (post's 14th field CODE|carrier)" "popup Parcels · Trailshop · ready to pick up (code 4821)" "$(K4_NOTIFY_FIXTURE=1 "$K4" --notifyd --dump < ../notify/parcel.txt 2>&1 | grep '^popup')"
check "notify: Discord's own notifications go while k4-discord follows the app (k4-discord.live fresh), stay otherwise" "notify 1 · dnd off|notify 2 · dnd off" "$( (r=$(mktemp -d); touch "$r/k4-discord.live"; printf 'discord\tMaja Lind\thi\nSlack\tAnna\thello\n' | XDG_RUNTIME_DIR=$r K4_NOTIFY_FIXTURE=1 "$K4" --notifyd --dump 2>&1 | head -1; rm -rf "$r"; printf 'discord\tMaja Lind\thi\nSlack\tAnna\thello\n' | XDG_RUNTIME_DIR=/nonexistent K4_NOTIFY_FIXTURE=1 "$K4" --notifyd --dump 2>&1 | head -1) | paste -sd'|')"
check "notify: immersive: the newest in the middle (1 of 2), its buttons; Super+← → steps, Super+Esc dismisses to the next" "box Messenger · Anna Berg · 1 of 2|  buttons Reply (Super+↵) · Mark read (m)|box Mail · Maja Lind · Saturday ride? · 2 of 2|box Messenger · Anna Berg" "$( (echo | ni | sed -n 2,3p; printf 'imm next\n' | ni | sed -n 2p; printf 'imm next\nimm esc\n' | ni | sed -n 2p) | paste -sd'|')"
check "notify: immersive: Super+N gives the box the keys (a message: its reply line), ↵ sends; Esc gives them back" "* box Messenger · Anna Berg · 1 of 2|  reply: |notify 1 · dnd off · immersive|box Mail · Maja Lind · Saturday ride? · 2 of 2" "$( (printf 'imm keys\n' | ni | sed -n '2p;4p'; printf 'imm keys\n' | ni --keys "see you<enter>" | head -1; printf 'imm next\nimm keys\n' | ni --keys "<esc>" | sed -n 2p) | paste -sd'|')"
check "notify: immersive: a critical one first; a fullscreen window or immersive off: the small cards" "box System · Battery critically low|  buttons Hibernate (Super+↵) · Power saver (p)|popup Messenger · Anna Berg|popup Messenger · Anna Berg" "$( (K4_NOTIFY_FIXTURE=1 "$K4" --notifyd --dump < ../notify/critical.txt | sed -n 2,3p; echo | K4_NOTIFY_FULLSCREEN=1 ni | sed -n 2p; printf 'immersive off\n' | ni | sed -n 2p) | paste -sd'|')"
check "notify focus: the first card picked, ↓ the next, warn marked" "* popup System · Battery critically low · 5%|* popup Drives · Can’t eject STICK yet (warn)" "$( (nf | sed -n 2p; nf --keys "<down>" | sed -n 3p) | paste -sd'|')"
check "notify focus: r replies in the card, ↵ sends it and it goes" "* popup Signal · Anna (reply: hi there)|notify 7 · dnd off" "$( (nf --keys "<down><down>rhi there" | sed -n 4p; nf --keys "<down><down>rok<enter>" | head -1) | paste -sd'|')"
check "notify focus: Del dismisses, Space shows only the app's notes, Esc lets go" "notify 7 · dnd off|1|popup System · Battery critically low · 5%" "$( (nf --keys "<del>" | head -1; nf --keys " " | grep -c popup; nf --keys "<esc>" | sed -n 2p) | paste -sd'|')"

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
cm() { K4_CLIP_NOW=1793020000 "$K4" --clip --dump "$@" < ../clip/meta.txt 2>&1; }
check "clip: the app; a secret masked, counting down, gone after 12 s" "clip All · 4 of 5|* •••••••••• · text · secret · from Bitwarden · expires in 7 s|  rgb(59, 130, 246) · text · 17 chars · 3 min · from firefox" "$(cm | head -3 | paste -sd'|')"
check "clip: search never finds a secret" "clip All · 0 of 5" "$(cm --keys "hunt" | head -1)"
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
check "perf: a utility runs in the background; another one waits" "running thumbs|toast Clear thumbnails is still running · this one waits" "$(K4_PERF_NOKILL=1 "$K4" --perf --dump --keys "3<down><enter><enter>" < ../perf/slow.txt 2>&1 | grep -E '^(running|toast)' | paste -sd'|')"
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
check "drives: m e y p and enter" "(unmount /dev/sdb1)|(eject /dev/sdb1)|(copy /dev/sdb1)|(paste /dev/sdb1)|(open /dev/sdb1)" "$(for k in m e y p "<enter>"; do dr --keys "$k" | grep '^toast' | cut -c7-; done | paste -sd'|')"
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
check "bus: g groups by direction where the stop has no platforms" "  [→ Teleborg]|* 3 Teleborg · 4 min|  [→ Hov]" "$(bu --keys "g" < <(awk -F'\t' 'BEGIN{OFS="\t"} $1=="D"{$9=""}1' ../bus/departures.txt) | sed -n 2,4p | paste -sd'|')"
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
mt() { printf 'S\tA\tApps\tA\t\n' | env -u WAYLAND_DISPLAY "$K4" --menu --dump "$@" 2>&1; }   # no display: copying does nothing
check "calc: percent, units; enter copies" "toast Copied  3.106855961 mi" "$(mt --keys "=5 km in mi<enter>" | grep toast)"
check "calc: ctrl+enter copies rounded" "toast Copied  1.78" "$(mt --keys "=1920 / 1080<ctrl-enter>" | grep toast)"
check "calc: shift+enter pastes into the window below" "paste:360" "$(mt --keys "=15% of 2400<shift-enter>")"
check "calc: up recalls the history" "query 2 GiB in MB" "$(hist=$tmp/calc-hist; K4_CALC_HISTORY=$hist mt --keys "=2 GiB in MB<enter>" >/dev/null; K4_CALC_HISTORY=$hist mt --keys "=<up>" | grep '^query')"
check "web: alt+2 searches Wikipedia" "url:https://duckduckgo.com/?q=%21w+arch+linux" "$(mt --keys "g arch linux<alt-2>" | tail -1)"
check "web: ctrl+enter copies the URL" "toast Copied  https://duckduckgo.com/?q=arch+linux" "$(mt --keys "g arch linux<ctrl-enter>" | grep toast)"
# the launcher: > settings, ⌃1–9, ⇧↵, the Files group (K4_FILES_CMD stands in for fd)
lt() { printf 'S\tA\tApps\tA\t\nA\tterm\tTerminal\t\t\tapp\nA\twifi\tWi-Fi power\t\t\tstay;toggle=on\nA\tvol\tVolume\t\t\tslider=50;step=5\nA\tdocs\tOpen docs\t\t\t\nR\techo ran\n' | env -u WAYLAND_DISPLAY K4_FILES_CMD='printf "%s\n" /home/u/Documents/invoice.pdf /home/u/inv/x.txt' "$K4" --menu --dump "$@" 2>&1; }
check "launcher: > lists only switches, sliders and choices" "crumb > SETTINGS|count 2 settings|* Wi-Fi power | Apps|  Volume | Apps" "$(lt --keys ">" | grep -v -E '^(focus|query|hints)' | paste -sd'|')"
check "launcher: > then ⌫ goes back to the menu" "crumb MENU" "$(lt --keys "><bs>" | sed -n 2p)"
check "launcher: ⌃3 runs the third result in place" "toast ran vol" "$(lt --keys "o<ctrl-3>" | grep '^toast')"
check "launcher: ⇧↵ opens an app and keeps the launcher" "focus Menu|toast ran term" "$(lt --keys "term<shift-enter>" | grep -E '^(focus|toast)' | paste -sd'|')"
check "launcher: files after the rest, ↵ opens, ⇧↵ shows the folder" "* /home/u/Documents/invoice.pdf | file|file:/home/u/Documents/invoice.pdf|reveal:/home/u/Documents/invoice.pdf" "$( (lt --keys "invoice" | grep '| file'; lt --keys "invoice<enter>" | tail -1; lt --keys "invoice<shift-enter>" | tail -1) | paste -sd'|')"
# Claude: data from a file at a pinned clock; a stand-in runner streams an answer (tests/claude/runner.sh)
cl() { K4_CLAUDE_NOW=1793100000 "$K4" --claude --dump "$@" 2>&1; }
clr() { (cat ../claude/data.txt; printf 'R\tsh ../claude/runner.sh\n') | cl "$@"; }
check "claude: the question streams a Markdown answer; its time and model; the session kept" "q write a timer · 09:44 · sonnet|a Two units in \`~/.config/systemd/user/\`.|session 3f13d34d" "$(clr --keys "write a timer<enter>" | grep '^q \|^a \|^session' | paste -sd'|')"
check "claude: the stream's limits reach the usage page" "5-hour window · 66% · resets 15:30 · in 1 h 44 min" "$(clr --keys "hi<enter><alt-3>" | grep '5-hour')"
check "claude: sessions, needs you first, the longest waiting in each group first" "* waiting design-gaps · /home/kr4nk/repos/dotfiles · permission prompt|  busy nightly-review · /home/kr4nk/repos/k4|  busy k4-integrations-six · /home/kr4nk/repos/k4" "$(cl --keys "<tab>" < ../claude/data.txt | sed -n 2,4p | paste -sd'|')"
check "claude: enter jumps, n picks a folder, x asks then stops a background one" "toast (jump 2961975)|toast (new /home/kr4nk/repos/k4)|toast (stop ab12cd)" "$( (cl --keys "<tab><enter>" < ../claude/data.txt | grep '^toast'; cl --keys "<tab>n<enter>" < ../claude/data.txt | grep '^toast'; cl --keys "<tab><down>xy" < ../claude/data.txt | grep '^toast') | paste -sd'|')"
check "claude: an interactive one is not stopped from here" "toast Only background sessions can be stopped from here · this one runs in a terminal" "$(cl --keys "<tab><down><down>x" < ../claude/data.txt | grep '^toast')"
check "claude: ← → change the model only with an empty field; the popup opens on sessions" "toast (model fable)|typing a|claude sessions · sonnet · 4 sessions" "$( (cl --keys "<right>" < ../claude/data.txt | grep '^toast'; cl --keys "a<right>" < ../claude/data.txt | grep '^typing'; cl --popup 600,80,1280,right < ../claude/data.txt | head -1) | paste -sd'|')"
# icons only (B icons=1): each module its icon and tags; text-only modules and the title hide; the clock its time
printf 'B\theight=26\ticons=1\nM\tws\tleft\tworkspaces\t-\t0\t-\t-\t-\t-\t-\t-\nM\tclk\tcenter\tclock\tT1;D1\t0\t-\t-\t-\t-\t-\t-\nM\tvol\tright\texec\techo "{\\"icon\\":\\"I\\",\\"text\\":\\"62%%\\",\\"text2\\":\\"x\\",\\"level\\":40}"\t30\t-\t-\t-\t-\t-\t-\nM\tbat\tright\texec\techo "{\\"battery\\":9,\\"text\\":\\"9%%\\"}"\t30\t-\t-\t-\t-\t-\t-\nM\tplain\tright\texec\techo "just text"\t30\t-\t-\t-\t-\t-\t-\nM\tdc\tright\texec\techo "{\\"icon\\":\\"D\\",\\"badge\\":3}"\t30\t-\t-\t-\t-\t-\t-\n' > "$tmp/spec5"
check "bar: icons only" "center: [T1]|right: [I] [bat:9] [D badge:3]" "$(K4_BAR_WORKSPACES=one-output.json "$K4" --bar --dump -w 1000 < "$tmp/spec5" 2>&1 | sed -n 2,3p | paste -sd'|')"
# k4-todo (todo.py from the dotfiles, when installed): the bar module beside the clock, on the fake Tasks API
TODO_PY="$HOME/.local/share/k4/todo.py"
if [ -f "$TODO_PY" ]; then
  tdir=$(mktemp -d)
  td() { K4_TODO_FAKE="$tdir/todo" K4_TODO_NOW=1793352734 python3 -I "$TODO_PY" "$@"; }
  cp -r ../todo "$tdir/todo"; td sync >/dev/null
  check "todo: the bar shows the most urgent due todo, how many are due, red for an overdue one" '{"icon": "󰄱", "text": "Renew the passport", "pill": "2", "icon_tone": "red", "badge_tone": "red"}' "$(td bar | python3 -c 'import json,sys; o=json.load(sys.stdin); o.pop("tooltip"); print(json.dumps(o, ensure_ascii=False))')"
  td done-next >/dev/null
  check "todo: a right click ticks off the first due todo, with an Undo card" "Done · Renew the passport | 1 more due | undo:Undo" "$(cat "$tdir/todo/posts.log")"
  td done a2 >/dev/null
  check "todo: nothing due: the bar module hides" "{}" "$(td bar)"
  check "todo: “· fri” after a todo is its due date" "Added · Buy milk · Fri 6 Nov" "$(td add "Buy milk · fri")"
  touch "$tdir/todo/offline"
  check "todo: offline, a change waits in the queue (and the page says so)" "Added · Water the plants · sends when online|1" "$(td add "Water the plants")|$(td page | grep -c '1 waiting to send')"
  rm "$tdir/todo/offline"; td sync >/dev/null
  check "todo: back online, the queue is sent" "[]|1" "$(cat "$tdir/todo/state/queue.json")|$(grep -c 'Water the plants' "$tdir/todo/log")"
  check "todo: k4's own todos carry their source, ticked ones can be reopened" "1|1" "$(td page | grep -c 'chip=K4')|$(td page | grep -c 'Ticked off by k4')"
  rm -rf "$tdir"
fi

# k4 on a Raspberry Pi (k4-pi, from the dotfiles when installed): cards wait in an outbox, secrets come
# from a file store, the finder reads the Discord DMs and mentions the desktop relays and never yields to a game
K4SH="$HOME/.local/share/k4"; PISECRET="$HOME/repos/dotfiles/pi/.local/bin/k4-secret"
if [ -f "$K4SH/k4host.py" ] && [ -x "$PISECRET" ]; then
  pdir=$(mktemp -d)
  export K4_CARDS="$pdir/cards.jsonl"   # (the phone's copy of each card: never the real one)
  check "pi: a card waits in the outbox (no display there)" '|post	0	Todo	T	B	done' "$(K4_HOST=pi K4_OUTBOX="$pdir/out" python3 -c "import sys; sys.path.insert(0, '$K4SH'); import k4host; print(k4host.post('post\t0\tTodo\tT\tB\tdone'))")|$(jq -r .line "$pdir/out")"
  # the phone's copy: numbered, the last 200 kept, the line read as app, title, body, urgency, tag, buttons
  K4_HOST=pi K4_OUTBOX="$pdir/out" python3 -c "import sys; sys.path.insert(0, '$K4SH'); import k4host
for i in range(205): k4host.post('post\t0\tPi-hole\tPi-hole isn’t answering\tlookups fail\twarn\t-1\t-1\tDOWN\t\t\topen:Open,pause:Pause\tk4-pihole card\t')"
  check "pi: the phone's cards: numbered, the last 200, read for the phone" "200|206|Pi-hole|warn|DOWN|open:Open pause:Pause" "$(python3 -c "import sys; sys.path.insert(0, '$K4SH'); import k4host
r = k4host.cards(); p = k4host.parse(r[-1]['line'])
print('%d|%d|%s|%s|%s|%s' % (len(r), r[-1]['seq'], p['app'], p['urgency'], p['tag'], ' '.join(a['key'] + ':' + a['label'] for a in p['actions'])))")"
  printf 'tok' | K4_SECRETS_DIR="$pdir/sec" "$PISECRET" store google k4-google-tasks
  check "pi: k4-secret's file store (0600, by name)" "tok|600|k4-google-tasks" "$(K4_SECRETS_DIR="$pdir/sec" "$PISECRET" lookup google k4-google-tasks)|$(stat -c %a "$pdir"/sec/google/*)|$(K4_SECRETS_DIR="$pdir/sec" "$PISECRET" names google)"
  cp -r ../events "$pdir/f"
  K4_HOST=pi K4_OUTBOX="$pdir/out2" K4_EVENTS_FAKE="$pdir/f" K4_EVENTS_STATE="$pdir/st" K4_CAL_DIR="$pdir/f/cal" K4_EVENTS_GAMING=1 K4_EVENTS_NOW=1793352734 python3 -I "$K4SH/events.py" scan >/dev/null
  check "pi: the finder reads the desktop's Discord DMs and mentions" "1" "$(grep -c '· discord ·' "$pdir/f/prompt")"
  unset K4_CARDS
  rm -rf "$pdir"
fi

# k4-pihole (pihole.py from the dotfiles, when installed) against a fake Pi-hole v6 (tests/pihole/api)
PH_PY="$HOME/.local/share/k4/pihole.py"
if [ -f "$PH_PY" ]; then
  phd=$(mktemp -d); cp -r ../pihole/api "$phd/api"
  ph() { K4_PIHOLE_FAKE="$phd/api" K4_PIHOLE_PASSWORD=app-pw K4_PIHOLE_NOW="${PHNOW:-1793352734}" XDG_RUNTIME_DIR="$phd/api" python3 -I "$PH_PY" "$@"; }
  phj() { python3 -c "import json,sys; json.dump(json.loads(sys.argv[2]), open(sys.argv[1], 'w'))" "$phd/api/$1.json" "$2"; }
  check "pihole: a wrong app password is refused, the right one connects" "Pi-hole: wrong password · Apps › Pi-hole|Connected to Pi-hole on kr4nkenhole" "$(K4_INPUT=nope ph setup-password | head -1)|$(K4_INPUT=app-pw ph setup-password)"
  check "pihole: the bar: the shield and today's blocked share (KPiholeBar)" '{"shape": "shield-on", "text": "18%"}' "$(ph bar | python3 -c 'import json,sys; o=json.load(sys.stdin); o.pop("tooltip"); print(json.dumps(o, ensure_ascii=False))')"
  ph pause 300 >/dev/null; phj dns_blocking '{"blocking": "disabled", "timer": 272}'; ph tick
  check "pihole: paused: the call, the bar counts down in yellow at a fixed width, a card" 'POST /api/dns/blocking {"blocking": false, "timer": 300}|OFF 4:32 yellow 86 shield-off|Ad blocking is off · back on in 5 min ' "$(tail -1 "$phd/api/log")|$(ph bar | jq -r '.text + " " + .icon_tone + " " + (.minw|tostring) + " " + .shape')|$(tail -1 "$phd/api/posts.log" | cut -d'|' -f1)"
  phj dns_blocking '{"blocking": "enabled", "timer": null}'; ph tick
  check "pihole: back on: a card with how long it was off" "Ad blocking is back on | Off for 0 min · 0 queries passed unfiltered meanwhile | done" "$(tail -1 "$phd/api/posts.log")"
  touch "$phd/api/down"; ph tick; ph tick; ph tick
  check "pihole: not answering twice: the red block, a cracked shield, one card (not one a minute)" "DNS down critical shield-broken|1" "$(ph bar | jq -r '.text + " " + .class + " " + .shape')|$(grep -c "isn’t answering" "$phd/api/posts.log")"
  rm "$phd/api/down"
  phj unbound '{"ok": false, "resolves": true, "dnssec": false, "why": "DNSSEC validation failing"}'; PHNOW=1793353100 ph tick
  check "pihole: unbound's DNSSEC failing: a card, the bar's red ! shield (no fill)" "unbound: DNSSEC validation failing | Lookups still resolve, but answers aren’t verified · a broken-signature test domain resolved | warn|DNSSEC shield-unsafe red" "$(tail -1 "$phd/api/posts.log")|$(PHNOW=1793353100 ph bar | jq -r '.text + " " + .shape + " " + .text_tone')"
  phj info_messages '{"messages": [{"id": 7, "timestamp": 1, "type": "LOAD", "plain": "Long-term load is high"}]}'; PHNOW=1793353100 ph tick; PHNOW=1793353100 ph tick
  check "pihole: Pi-hole's own message, once" "1" "$(grep -c 'Long-term load' "$phd/api/posts.log")"
  touch "$phd/api/certchanged"; ph tick
  check "pihole: a changed certificate: refused, the page asks to trust it" "Trust the new certificate" "$(ph page | grep -o 'Trust the new certificate')"
  rm -rf "$phd"
fi

# Group bar items (the KGroups board): each group one chip, the most urgent member speaking for it
grp() { K4_BAR_PINS=/nonexistent K4_BAR_WORKSPACES=one-output.json "$K4" --bar --dump -w 1400 "$@" 2>&1 | sed -n 3p; }
check "bar groups · quiet: a transfer's %, the unread sum, the pinned weather and volume; WoW's yellow gold isn't trouble; the battery stays" \
  "right: <status 68%> <apps badge:6> <info 6°> <network> <system 62%> [bat:78 78%]" "$(grp < groups.txt)"
check "bar groups · busy: recording in red, a red mention, CPU yellow, DNS down fills, a muted mic and the layout join System" \
  "right: <status 02:14 red> <apps badge:8 red/red> <info 84% yellow> <network DNS down fill> <system · X se red> [bat:78 78%]" "$(grp < groups-busy.txt)"
check "bar groups: off, the modules as they are" "right: [n] [d 68%] [m badge:3] [e badge:3] [w 452g] [c 18% · 6.2G] [p 6°] [◇ 18%] [W] [M] [V 62%] [us (dim)] [bat:78 78%]" "$(sed 's/groups=1/groups=0/' groups.txt | grp)"
check "bar groups: a pinned member's value on the quiet chip (the pins file)" "right: <status 68%> <apps badge:6> <info 18%> <network> <system 62%> [bat:78 78%]" \
  "$(printf 'info perf\n' > "$tmp/pins"; K4_BAR_PINS="$tmp/pins" K4_BAR_WORKSPACES=one-output.json "$K4" --bar --dump -w 1400 < groups.txt 2>&1 | sed -n 3p)"
# a group's drawer (k4 --bardrawer): members with their chips, attention first, ON CHIP, not showing
bdr() { (cat ../bardrawer/info.txt; printf 'R\tsh ../youtube/runner.sh\n') | "$K4" --bardrawer --dump "$@" 2>&1; }
check "bar drawer: the summary, the groups, members (attention first), ON CHIP, not showing" "drawer Info · Chip shows Performance · 84%|groups Status Apps [Info] Network System|* Performance [84%] sev2|  Weather [6°] ON CHIP|-- not showing" \
  "$("$K4" --bardrawer --dump < ../bardrawer/info.txt | grep -a '^drawer\|^groups\|Performance\|Weather\|^--' | paste -sd'|')"
check "bar drawer: ↵ opens the member's popup, ← → the next group, ⌃P puts it on the chip" "toast (open perf)|toast (nav 1)|toast (pin perf)" \
  "$(bdr --keys "<enter>" | grep -a '^toast')|$(bdr --keys "<right>" | grep -a '^toast')|$(bdr --keys "<ctrl-p>" | grep -a '^toast')"

# the Pi-hole popup (k4 --pihole, the KPihole board): pihole.py window-data's lines from the fake Pi-hole
phw() { local f="$1"; shift; "$K4" --pihole --dump "$@" < "../pihole/window-$f.txt" 2>&1; }
phr() { local f="$1"; shift; (cat "../pihole/window-$f.txt"; printf 'R\tsh ../youtube/runner.sh\n') | "$K4" --pihole --dump "$@" 2>&1; }
check "pihole popup: status, today's numbers, unbound; PAUSE picked" "status Blocking on · 18240 queries · 3362 blocked · 18.4% · 9 clients|unbound ok · 24 ms · 71% hits|* pause 5 min" "$(phw normal | sed -n '2p;3p;5p' | paste -sd'|')"
check "pihole popup: ← → picks how long, ↵ pauses" "toast (pause 1800)" "$(phr normal --keys "<right><enter>" | grep '^toast')"
check "pihole popup: a blocked query: ↵ allows it; an allowed one: ⌃B blocks it" "toast (allow ads.tracker.example)|toast (block news.example.org)" "$(phr normal --keys "<down><down><enter>" | grep '^toast')|$(phr normal --keys "<down><down><down><ctrl-b>" | grep '^toast')"
check "pihole popup: typing filters the log by domain or device" "find tv|* × metrics.tv.example [YOUR DENY] · 192.168.1.60" "$(phw normal --keys "tv<down>" | grep '^find\|^\*' | paste -sd'|')"
check "pihole popup: paused: Resume picked, the countdown" "status Blocking off 4:12 · 18240 queries · 3362 blocked · 18.4% · 9 clients|* pause resume" "$(phw paused | sed -n '2p;5p' | paste -sd'|')"
check "pihole popup: DNS down: Restart FTL (unbound answers)" "  unbound restart FTL" "$(phw down | grep 'unbound restart')"
check "pihole popup: DNSSEC failing: Restart picked first" "* unbound restart" "$(phw dnssec | grep 'unbound restart')"
check "pihole popup: setup: the pasted password masked, ↵ connects with it as the secret" "field ••••••|toast (setup-password)" "$(K4_MESSENGER_CLIPBOARD=app-pw phw setup --keys "<ctrl-v>" | grep '^field')|$(K4_MESSENGER_CLIPBOARD=app-pw phr setup --keys "<ctrl-v><enter>" | grep '^toast')"
check "pihole popup: a changed certificate: both fingerprints, Trust first" "fp TRUSTED|fp NEW|* c1" "$(phw cert | grep -o '^fp [A-Z]*\|^\* c1' | paste -sd'|')"

# Toggles › Bar items: a module switched off is not in the bar's spec at all; k4-bar items says it's off
if command -v k4-bar >/dev/null; then
  bh=$(mktemp -d); mkdir -p "$bh/.local/state/sway"; printf 'weather\npihole\n' > "$bh/.local/state/sway/bar-hidden"
  check "bar items: switched off modules are left out of the spec, items reports them off" "0|weather off|audio on|pihole off" \
    "$(HOME="$bh" PATH="$HOME/.local/bin:$PATH" k4-bar spec 2>/dev/null | awk -F'\t' '$1 == "M" && ($2 == "weather" || $2 == "pihole")' | wc -l)|$(HOME="$bh" PATH="$HOME/.local/bin:$PATH" k4-bar items 2>/dev/null | awk -F'\t' '$1 == "weather" || $1 == "pihole" || $1 == "audio" { print $1 " " $5 }' | paste -sd'|')"
  rm -rf "$bh"
fi

echo "bar tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
