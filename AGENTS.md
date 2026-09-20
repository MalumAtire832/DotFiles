# AGENTS.md

Context for agents working in this repository.

## What this is

Personal dotfiles for a Wayland desktop, themed to oxocarbon. See `README.md`
for the user-facing description.

The important thing to understand before editing anything: this repository is
not a copy of the configuration, it *is* the configuration. `~/.config/sway`
and `~/.files/config/sway` are the same directory reached by two paths, via a
symlink. Editing either one edits the live desktop of a machine that is
probably running right now.

Consequences:

- A config change takes effect the moment the relevant tool reloads. Nothing
  is staged.
- `~/.config/sway/config` and `config/sway/config` are the same file. Do not
  "copy changes across" — you will be copying a file onto itself.
- A broken sway config can leave the user unable to use their desktop.
  Validate before suggesting a reload.

## Layout

```
config/        -> symlinked to ~/.config/<name>   (whole directories)
  btop cava helix kitty mako rofi sway waybar
home/          -> symlinked to ~/<name>
  .zshrc .zprofile .zsh/
docs/          palette.svg, referenced by README
install.sh     creates the 11 symlinks; idempotent
```

Directories are linked whole, not file by file. This is deliberate: an
application that saves settings by writing a temp file and renaming it over
the original would replace a file-level symlink with a real file and silently
detach from the repository. btop rewrites its own config on exit. Do not
convert these to per-file links.

A corollary: a new file dropped into `config/sway/` is live immediately and
tracked automatically. No `install.sh` change is needed.

## Coupled files

These are the traps. Changing one side without the other breaks things
quietly, with no error.

### Monitor names appear in three files

`DP-2` (left), `HDMI-A-1` (centre), `DP-1` (right) are hardcoded in:

| File | Where |
|------|-------|
| `config/sway/config` | `set $monitor_*` at lines 23-25, and a comment block at 43-45 |
| `config/sway/ws.sh` | the `case "$out"` prefix mapping, lines 30-32 |
| `config/waybar/config.jsonc` | `"output"` on the main bar (line 11) and the side bar (line 212) |

Renaming an output means editing all three. `ws.sh` fails soft — an unknown
output silently falls back to the centre workspace bank — so a missed edit
shows up as "Super+N goes to the wrong monitor", not as an error.

### Workspace numbering appears in four places

Workspaces are namespaced per monitor: `11`-`19` left, `21`-`29` centre,
`31`-`39` right. Nine workspaces per monitor, each monitor independent.

- `config/sway/config` assigns each workspace to an output.
- `config/sway/ws.sh` resolves the prefix from the focused output, so
  `Super+N` is relative to the monitor you are on.
- `config/waybar/config.jsonc` relabels `11`-`19` back to `1`-`9` for
  display, in a `format-icons` map — and there are two such maps, one per
  bar (lines 62 and 227). Editing only the first is the easy mistake.

### The palette is duplicated per tool

Each tool defines oxocarbon in its own file, in its own syntax. There is no
single source of truth, because none of these tools can share one:

| Tool | Palette file |
|------|--------------|
| sway | `config/sway/oxocarbon.txt` |
| kitty | `config/kitty/oxocarbon.conf` |
| rofi | `config/rofi/colors.rasi` |
| btop | `config/btop/themes/oxocarbon.theme` |
| helix | `config/helix/themes/oxocarbon.toml` |
| cava | `config/cava/config` |
| mako | `config/mako/config` |

Changing a colour means changing it everywhere it is used. The canonical hex
values are listed in `README.md`.

Note one deliberate divergence from upstream oxocarbon: upstream has no
yellow and parks light blue in terminal slot 3. Here slot 3 carries Carbon
yellow-40/30 so warnings and diffs read as yellow. Do not "fix" this back.

Colours belong in the palette file, not inline in a config. `kitty.conf` once
set `url_color` after including the theme and silently overrode it; that was
a bug, and reintroducing the pattern will cause the same class of bug.

## Verifying changes

Run the relevant check before claiming a change works. All are cheap.

| Change to | Check |
|-----------|-------|
| sway config | `sway --validate` — exits 0 and prints nothing when clean |
| any shell script | `bash -n <script>` (or `sh -n` for `ws.sh`) |
| mako config | `makoctl reload`, then `pgrep mako` to confirm it survived |
| zsh config | `timeout 20 zsh -i -c 'echo ok'` |
| waybar config | `.jsonc` allows comments, so use waybar itself, not `jq` |
| symlink integrity | `./install.sh` — reports `ok` for all 11 and changes nothing |

## Applying changes to the running session

The user's desktop is live. These reload without restarting the session:

| Tool | How |
|------|-----|
| sway | `swaymsg reload`, or Mod+Shift+C |
| waybar | `~/.config/waybar/launch_waybar.sh` (replaces the running instance) |
| mako | `makoctl reload` |
| kitty | new windows pick it up; Ctrl+Shift+F5 reloads an open one |
| btop, helix, rofi, cava | restart the application |
| zsh | open a new shell |

Prefer telling the user which command to run over running it yourself, unless
they asked you to apply it. A `swaymsg reload` at the wrong moment is
disruptive.

## Conventions

Configs carry explanatory comments where behaviour is non-obvious, written as
prose explaining *why*, not restating the setting. Match that density; do not
add a comment to every line, and do not strip the existing ones.

Scripts are POSIX `sh` where they can be (`ws.sh`) and bash where they need to
be. They open with a comment block stating purpose and usage. They use
`set -eu`.

Commit messages: imperative subject under about 50 characters, blank line,
then prose explaining the reasoning. Not bullet lists. Existing history shows
the style.

## Adding a tool

Move its directory into `config/` and run `./install.sh`. Nothing else is
needed — `.gitignore` names specific unwanted files rather than defaulting to
exclusion, so a new directory is tracked automatically.

## Deliberately ignored

`.gitignore` excludes timestamped `*.bak-*` and `*.backup-*` backups — the
latter is what `install.sh` leaves behind — plus `waybar/old/`,
`config/sway/.claude/`, `config/cava/config1`, and three leftover catppuccin
theme files. These still exist on disk. Do not resurrect them, and do not
assume a file's presence on disk means it is tracked.

## Hardware assumptions

Three monitors as above; a 3840x2160 centre at 120Hz flanked by two rotated
2560x1440 panels. An AMD GPU — the waybar GPU modules read `amdgpu` sysfs
paths and pick the discrete card by VRAM size, reporting nothing elsewhere.
A Dvorak keyboard with Caps as Compose. Locking is disabled deliberately.

Wallpapers live in `config/sway/wallpapers/`, named
`wallpaper_<output>_<n>`. Downscale to the target output's resolution before
committing; the source image for the current one was 22016x12288 and 13 MB,
against a 3840x2160 display.

## Open items

`README.md` has a TODO section. It is the current list; prefer it over
inferring work from the code.

## A note on discoverability

This file sits at the repository root, so an agent started in `~/.files` will
find it. An agent started in `~/.config` — which is where a user is just as
likely to be when they ask for a config change — will not, because
`~/.config` is not the repository. If you are reading this after being
pointed at it manually, that is why.
