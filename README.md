# k4

A dmenu-style launcher for wlroots compositors (Sway, Hyprland, river…), written in Odin.
Drop-in for the parts of fuzzel that `sway-menu` in the dotfiles uses, plus what fuzzel
1.9 cannot do: width that fits the rows, thumbnails straight from JPEG/PNG, and the
desktop theme and font read live from the Omarchy-format state files.

```sh
printf 'Firefox\nfish\nnvim\n' | k4 --prompt 'Run ❯ '
printf 'Nord\0icon\x1f/path/preview.png\n' | k4 --index
k4 --prompt-only 'Password ❯ ' --password
```

`k4 --help` lists every option.

## How it works

- **Window:** a `zwlr_layer_shell_v1` overlay with exclusive keyboard focus, drawn in
  software into `wl_shm` buffers, re-rasterised at the output's integer scale.
- **Keyboard:** libxkbcommon keymaps, compose sequences (dead keys, `compose:caps`), key repeat.
- **Text:** fontconfig picks the file (the installed family of exactly that name, else
  `fc-match`), kb_text_shape shapes it (ligatures,
  kerning), stb_truetype rasterises; a sans-serif face fills in missing glyphs.
- **Matching:** space-separated terms, each a case-insensitive fuzzy subsequence, ranked
  for consecutive runs and word starts.
- **Theme:** `~/.local/state/omarchy/current/theme/colors.toml` and `…/current/font.name`,
  the same files Omarchy and the dotfiles' `sway-theme-set`/`sway-font-set` write.

## Menu mode

`k4 --menu` reads a tree on stdin (the format is at the top of `src/menu.odin`): sections
on the left, their actions on the right, and full-width pages, lists and picture grids.
Everything happens inside the launcher:

- **Pages** (`P`, `F` records) are pickers whose rows come from a command: Wi-Fi networks,
  fonts with a live preview, search results. ⌫ returns to the row that opened them.
- **In place:** `stay` rows and view items run through the `R` command while the menu stays
  open; its last line of output is shown in the footer, and the theme and font are read
  again, so a theme or font switch recolours the launcher itself.
- **Text input:** an `input=` row (or a `k4:input` line from the runner) asks for text in the
  header field, masked for passwords, and hands it over as `$K4_INPUT` in the runner's
  environment. Runner lines `k4:page`, `k4:back` and `k4:close` chain the next step.
- **Sliders and confirmations:** `slider=` rows adjust with ← →, `confirm=` rows ask first.
- **Integration components:** headings with count badges, rows with a status mark, sub
  text, chip, thumbnail or a `‹ choice ›` stepper, notices, empty lines, a now-playing card,
  progress rows and loading bars. A section's static lines show until its loader's output
  replaces them (a skeleton, or the last fetch), and `slow` lines appear when a loader takes
  8 s or more.

## Bar mode

`k4 --bar --output NAME` is a status bar along one output (Waybar's job), drawn as the Kestrel
design's strip: 26 px with a 2 px accent rule (dim on an output without focus), at the top or
the bottom, opaque or transparent. Modules come from stdin (format at the top of `src/bar.odin`):
workspaces (live from sway's IPC or Hyprland's sockets; 1–5 always there on a single output,
focused an accent block, visible elsewhere outlined, urgent red), the focused window's title
(dim, cut at 420 px, the first to give way), a clock (time bold, date dim; right click switches
format, middle click shows UTC; with `next=FILE` a meeting replaces the date 10 minutes before
and while it runs), and commands that print plain text or Waybar's JSON plus k4's
`icon`, `text2`, tones, a `level` bar, a `battery` glyph and a `badge` (the design's count tag
over the content's end: accent for unread, `badge_tone` red when the app needs you, `dnd` quiet;
the tray's chat apps use it). Hover fills the module and shows its
tooltip after 500 ms; 300 ms on a workspace shows a preview of its windows (a miniature in their
real places and a row per window; a click jumps to one, `src/wspreview.odin`); a left click's command is watched, so the module stays an accent block
while its popup is up. Clicks and the wheel get `K4_BAR_X`, `K4_BAR_MX`, `K4_BAR_MW`,
`K4_BAR_SIDE`, `K4_BAR_WIDTH`, `K4_BAR_OUTPUT`, `K4_BAR_POS` and `K4_BAR_H`.

`k4 --menu --open PAGE --popup X,W,OUT_W,SIDE[,bottom] --compact` is a module's popup: the
page alone in the design's 420 px frame (crumb, title, rows, key hints), fitted to its rows and
placed by the module's group, 4 px off the bar and 8 px from the screen edges. Esc closes it;
⌃↵ prints `launcher:PAGE` so the caller opens the same page in the full launcher. Pages can
ask for a width (`O width=N`), a large charge row (`X percent line [charging]`) and the calendar
(`O cal`, `src/cal.odin`): the design's 644 px clock popup with a Monday-first month grid (ISO
weeks, a dot per calendar), the day's events with a now line and the next meeting, an agenda,
event details (reply, join, open, copy, delete), quick add from plain text and the calendars,
over CS/CX/CC/CE/CG/CN lines a script prints (the dotfiles' `k4-cal`: Google Calendar).
Popup pages also take a fixed size (`O width=N;height=N`), a reload every N seconds while shown
(`O refresh=N`, scans), a status in the header (`ST text tone`), letters that run actions
(`KB key id`), a picture with a caption (`QR`), a large code (`BIG`), and rows with a second line,
a bold or coloured label, a lock, a small battery or a key column (`line2=`, `bold`, `labelc=`,
`lock`, `bat=`, `field=`); a password asked in a popup gets its own form (Tab shows it), and a run
can print `k4:launcher ID` to hand over to the full launcher. The bar's Wi-Fi and Bluetooth
popups are built from these.
A click outside any k4 menu closes it: a transparent surface under it catches the click, clear
of the bar.

`k4 --overview` (Super+Tab) shows every workspace at once over the dimmed desktop: a card per
workspace with its windows in miniature and listed; ←→↑↓ and 1–9 pick and go, Tab steps into a
card's windows (↵ focuses, x closes), ⇧↵ moves the focused window there, typing finds windows
across all of them (`src/overview.odin`). Its HUD palette comes from the theme (the background darkened,
the accent, red for alarms); `K4_OVERVIEW_ACCENT=#RRGGBB` picks another accent.

The bar, popups and the overview run Ghostty's shaders as the launcher does.

`k4 --osd 'ICON|PERCENT|MAX|VALUE|…'` is the on-screen display: 300×48 above the bottom of the
focused output for 1.2 s; another call while it shows updates it in place. With a sub line and a
picture it is a track: the cover, the title over the artist, a glyph (media keys, `media-menu`).

## Windows fed by scripts

Seven windows share `src/panel.odin`: the data comes on stdin, `R` names the script that runs
their actions in the background (its last line is the footer's message; `k4:` lines steer the
window) and `L` the one that loads the data again. Each file's header has its format.

| mode | what | script (dotfiles) |
|---|---|---|
| `--pass` | Passwords: the pass store, copy (cleared after 45 s), new, generate, git; a locked key asks for its passphrase in the window | `pass-menu`, Super+Ctrl+P |
| `--keyring` | the Wi-Fi and VPN passwords k4 keeps in the keyring, and its sign-in tokens: use, forget | `k4-secret` |
| `--media` | any MPRIS player: cover, position, controls, volume, the players | `media-menu`, the bar's media module |
| `--drives` | removable drives: mount, open, eject (busy: what holds it), unlock LUKS in the card | `k4-drives`, the bar's drives module |
| `--snap` | btrfs snapshots: take, compare, keep, delete, restore | `k4-snap`, Perf › Utilities |
| `--claude` | Claude: ask with your Claude Code login (streamed, tools off), the Claude Code sessions (jump, start, stop), the plan's usage windows | `k4-claude`, the bar's Claude module, Super+Alt+A |
| `--bus` | the next hour of departures at a remembered stop (Trafiklab Realtime API, key in the keyring), a stop search | `k4-bus`, the bar's bus module |

The tray popup takes an unread count per app (the count tag on its tile and NEEDS YOU row), and
the notification service answers `counts` (notes per app) for the bar's chat badges.

## Build

Needs [mise](https://mise.jdx.dev) (it installs the Odin version pinned in `mise.toml`), clang
and a C compiler, and the Wayland, xkbcommon and fontconfig libraries (on Ubuntu:
`clang libwayland-dev libxkbcommon-dev`). Without mise, any `odin` on PATH is used; on Ubuntu
make sure that is not the unrelated apt package of the same name.

```sh
./build.sh            # ./k4
./build.sh install    # ~/.local/bin/k4
./build.sh test       # unit tests (matcher, row parser, theme) and menu tests
```

`--dry-run out.png` renders one frame without a compositor and prints the row Enter
would pick, which is how layout and selection are tested headlessly. `--dump` prints the
menu's state as text instead; `tests/menu.sh` drives a fixture tree through pages, input,
directives, steppers, skeletons and slow loads with it and compares the result with
`tests/menu/expected/` (`UPDATE=1 tests/menu.sh` rewrites those after an intended change).

## Layout

| path | what |
|---|---|
| `src/` | the program: Wayland loop, input, layout, drawing, fonts |
| `src/logic/` | pure logic, unit-tested: dmenu rows, matcher, theme |
| `csrc/` | stb_truetype / stb_image / stb_image_write behind a tiny C API |
| `vendor/wayland/` | Odin Wayland bindings ([odin-wayland](https://github.com/yasinkaraaslan/odin-wayland), MIT) plus generated wlr-layer-shell |
| `vendor/kb_text_shape/` | Odin's kb_text_shape bindings and C source (MIT/zlib) |
| `protocols/` | protocol XML the bindings were generated from |
| `tests/` | `odin test` suite |

## Not yet

App-launcher mode, fractional scaling.
