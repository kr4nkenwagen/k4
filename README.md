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

## Build

Needs [mise](https://mise.jdx.dev) (it installs the Odin version pinned in `mise.toml`), clang
and a C compiler, and the Wayland, xkbcommon and fontconfig libraries (on Ubuntu:
`clang libwayland-dev libxkbcommon-dev`). Without mise, any `odin` on PATH is used; on Ubuntu
make sure that is not the unrelated apt package of the same name.

```sh
./build.sh            # ./k4
./build.sh install    # ~/.local/bin/k4
./build.sh test       # unit tests (matcher, row parser, theme)
```

`--dry-run out.png` renders one frame without a compositor and prints the row Enter
would pick, which is how layout and selection are tested headlessly.

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

Popups anchored to a bar module, clipboard paste, app-launcher
mode, fractional scaling.
