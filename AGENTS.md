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
  broot btop cava gtk-3.0 gtk-4.0 helix kitty mako rofi sway waybar zellij
home/          -> symlinked to ~/<name>
  .zshrc .zprofile
docs/          palette.svg, referenced by README
install.sh     creates the 14 symlinks; idempotent
```

Directories are linked whole, not file by file. This is deliberate: an
application that saves settings by writing a temp file and renaming it over
the original would replace a file-level symlink with a real file and silently
detach from the repository. btop rewrites its own config on exit. Do not
convert these to per-file links.

A corollary: a new file dropped into `config/sway/` is live immediately and
tracked automatically. No `install.sh` change is needed.

### `home/.zshrc` is an oh-my-zsh file

The shell is oh-my-zsh, installed at `~/.oh-my-zsh`. That directory is
upstream's own git clone and is deliberately *not* tracked here; the only
part of oh-my-zsh that is configuration is `home/.zshrc`, which is its
`.zshrc`, so that one file is the whole integration. There is no
`config/oh-my-zsh/`.

The consequence for editing is that oh-my-zsh already provides a great deal,
and re-adding any of it causes duplicate or conflicting work:

| Provided by | What |
|-------------|------|
| `lib/history.zsh` | `HISTFILE`, `HISTSIZE`, `SAVEHIST` and the history options |
| `lib/completion.zsh` | `compinit` and the completion styles |
| `lib/key-bindings.zsh` | `bindkey -e`, and Home/End/Delete/PageUp/word-skip from terminfo — 67 bindings |
| `ZSH_THEME="bira"` | the prompt |

An earlier version of this file hand-rolled the history, completion and
terminfo key-binding blocks and sourced a `headline` theme from `home/.zsh/`.
All of that is oh-my-zsh's now, and both the theme and the directory holding
it have been deleted. Do not reintroduce those blocks.

Two further things belong nowhere near this file. `rbenv` is initialised in
`home/.zprofile`, so a second `rbenv init` in `.zshrc` is a duplicate. And
`XDG_CURRENT_DESKTOP` is exported by the session — `config/sway/config` imports
it into systemd and dbus, where it reads `sway:wlroots:swayfx`. Setting it in
`.zshrc` does not add it, it *overwrites* it with a bare `sway` in every
interactive shell. It was doing exactly that until it was removed.

Anything added to `.zshrc` must go after `source $ZSH/oh-my-zsh.sh`, or
oh-my-zsh will load over the top of it.

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
| zellij | `config/zellij/config.kdl`, in a `themes` block rather than its own file |
| broot | `config/broot/oxocarbon.hjson`, imported into `conf.hjson` |
| GTK 3 | `config/gtk-3.0/oxocarbon.css` |
| GTK 4 | `config/gtk-4.0/oxocarbon.css` |

Changing a colour means changing it everywhere it is used. The canonical hex
values are listed in `README.md`.

Note one deliberate divergence from upstream oxocarbon: upstream has no
yellow and parks light blue in terminal slot 3. Here slot 3 carries Carbon
yellow-40/30 so warnings and diffs read as yellow. Do not "fix" this back.

Colours belong in the palette file, not inline in a config. `kitty.conf` once
set `url_color` after including the theme and silently overrode it; that was
a bug, and reintroducing the pattern will cause the same class of bug.

The two GTK files are an exception only in shape, not in rule: `gtk.css` holds
structural rules and `oxocarbon.css` holds the colours, so a rule in `gtk.css`
names `@theme_header_bg` and never a hex code.

### The broot opener is coupled to helix

`config/broot/opener.sh` gives each file broot opens its own helix process,
rather than a buffer in a shared one, and merges those panes into a single
zellij stack next to the file tree. Three things have to agree:

| File | What it states |
|------|----------------|
| `config/broot/verbs.hjson` | the `edit` verb, bound to `enter`, `apply_to: text_file`, pointing at `~/.config/broot/opener.sh` |
| `home/.zshrc` | `EDITOR`, which `opener.sh` hands new helix panes and nothing else needs |
| `config/broot/opener.sh` | that a file's editor is whichever pane's `pane_command` is exactly `hx <path>` |

Unlike the old `NNN_OPENER` string, broot's `external` field is not shell-
expanded: a literal `$HOME` in `verbs.hjson` fails with "Unable to launch $",
not a resolved path. Use `~` instead — broot expands that one itself, the
same way its own default `special_paths` example does.

There's no mime-type check in `opener.sh` any more, unlike the old nnn one.
`apply_to: text_file` in the verb already restricts it to files broot itself
classifies as text; anything else never reaches this verb and falls through
to broot's own default (`xdg-open`), the same end result the mime check used
to produce by hand.

Without `jq`, the pane lookup comes back empty: a file already open gets a
second pane instead of being focused, and a newly opened one is never folded
into the others' stack. Wrong, but not destructive, and none of it produces
an error.

The lookup matches on the *running command*, deliberately. It used to match a
pane named `editor`, which worked only for panes the opener had created
itself and silently split a new pane off the file tree whenever helix had
been started any other way — from a zellij layout, say, which is the normal
case. `zellij action list-panes --command --state --geometry --json` is the
source of truth, and it needs `jq`: the table form of that command cannot be
parsed safely, because both the title and the command contain spaces.

A newly opened file is spawned as its own `hx <path>` pane and, if other
files are already open, folded into their stack with `zellij action
stack-panes` — merging by pane id, regardless of where the new pane first
landed, rather than by direction or focus, both of which depend on whatever
pane broot happens to be running in. The tradeoff against the old shared-pane
design is one language server per open file instead of one for the whole
project.

`opener.sh` resolves the `zellij` binary itself rather than calling it by
bare name (`zellij=$(command -v zellij || echo "$HOME/.local/bin/zellij")`).
zellij is installed to `~/.local/bin`, which is only on `PATH` inside an
interactive shell that has sourced `.zshrc` — a pane zellij itself spawns
(this one) starts with a bare default `PATH` regardless of what the
invoking shell had, so a bare `zellij action ...` inside a spawned pane
fails with "command not found" even though it's how the pane got started.
Any future script that calls back into `zellij` from inside a spawned pane
needs the same treatment.

broot's own shell-integration installer (the `br()` prompt) also runs the
first time broot is launched directly instead of through `br`, which is
exactly how the `ide` layout starts it — so it fires once per machine and
writes an install marker plus a `launcher/` symlink into `~/.config/broot`.
That's tool state, not configuration, and is `.gitignore`d the same way
nnn's session/mount/bookmark state used to be.

### GTK settings are stated in three places

`config/gtk-3.0/settings.ini`, `config/gtk-4.0/settings.ini` and the
`gsettings` block at the end of `config/sway/config` all name the theme, icon
theme, cursor and font. They must agree.

`xdg-desktop-portal-gtk` is running, so GTK prefers the gsettings values and
falls back to `settings.ini` only without the portal. A disagreement is
therefore invisible until the portal is missing, and then shows up as two
applications on one desktop using different cursors — never as an error. This
set had already drifted: `settings.ini` named a theme that was not installed
and gsettings named a cursor that was not either.

One asymmetry is deliberate. The GTK 3 file sets
`gtk-application-prefer-dark-theme` and the GTK 4 file does not, because
libadwaita rejects that key and warns on every start; it reads the gsettings
`color-scheme` key instead.

### The GTK 3 theme name is `Adwaita`, never `Adwaita-dark`

`/usr/share/themes/Adwaita-dark/` contains a `gtk-2.0` directory and an
`index.theme`, and nothing else. GTK 3 cannot resolve it, falls back to its
built-in default and lands on the *light* variant, so naming it produces a
white desktop. Dark GTK 3 is `gtk-theme-name=Adwaita` together with
`gtk-application-prefer-dark-theme=true`. This is set in three places and they
must agree; see above.

### `@define-color` repaints GTK 4 and does nothing to GTK 3

Adwaita's GTK 3 stylesheet defines 36 colour names and references them zero
times, painting from 787 literal hex values instead. Those definitions are an
API for other programs to read, not the theme's own palette. Redefining
`@theme_bg_color` therefore changes what a program reads out of the theme and
changes nothing about the window.

This is why `config/gtk-3.0/gtk.css` is two hundred lines of explicit rules
and `config/gtk-4.0/gtk.css` is a single import: libadwaita does resolve its
names at runtime. Do not "simplify" the GTK 3 file to match the GTK 4 one.

A consequence: any surface not named in that file keeps Adwaita's own dark
shade. If something looks grey rather than black, the selector is missing, not
the colour.

### Only `config/gtk-4.0/` reaches a libadwaita application

libadwaita ignores `~/.themes` completely, so no installed theme can colour a
modern GTK 4 application. `config/gtk-4.0/oxocarbon.css` is the only route.
This is why there is no theme directory here and why the base theme is stock
Adwaita-dark, repainted in place rather than replaced.

## Verifying changes

Run the relevant check before claiming a change works. All are cheap.

| Change to | Check |
|-----------|-------|
| sway config | `sway --validate` — exits 0 and prints nothing when clean |
| any shell script | `bash -n <script>` (or `sh -n` for `ws.sh`) |
| mako config | `makoctl reload`, then `pgrep mako` to confirm it survived |
| zsh config | `timeout 20 zsh -i -c 'echo ok'` |
| waybar config | `.jsonc` allows comments, so use waybar itself, not `jq` |
| GTK palette | ask GTK what it *paints*, not what it defines — see below |
| broot opener | `sh -n config/broot/opener.sh`, then open two files from broot and check each gets its own pane, both merged into one stack, and that reselecting one focuses it rather than duplicating it |
| zellij config | `zellij setup --check` — prints `[CONFIG FILE]: Well defined.` when the KDL parses |
| zellij layout | no validator; `zellij --layout <name>` in a throwaway session is the test |
| symlink integrity | `./install.sh` — reports `ok` for all 14 and changes nothing |

GTK has no validator. A malformed stylesheet is not an error; the bad rule is
dropped and the rest applied, so the only symptom is a colour that did not
change. Launching an application prints parse errors to stderr.

`lookup_color()` is not a check. It answers what a name is defined as, which
on GTK 3 is unrelated to what the widget paints — the theme defines those
names and then ignores them. A GTK 3 stylesheet can pass `lookup_color` on
every name while the window is still white. Ask for the painted colour:

    python3 -c "import gi; gi.require_version('Gtk','3.0'); \
      from gi.repository import Gtk; Gtk.init([]); \
      w=Gtk.Window(); w.show(); \
      print(w.get_style_context().get_background_color(Gtk.StateFlags.NORMAL).to_string())"

`get_background_color` is deprecated and still the only thing that answers the
question. On GTK 4 it is gone, and there `lookup_color` is meaningful, because
libadwaita does resolve its names at runtime.

Better still, take the screenshot: `grim -g "$(swaymsg -t get_tree | jq ...)"`
and count the colours in it. `thunar` is the GTK 3 test case and
`adwaita-1-demo` the libadwaita one.

## Applying changes to the running session

The user's desktop is live. These reload without restarting the session:

| Tool | How |
|------|-----|
| sway | `swaymsg reload`, or Mod+Shift+C |
| waybar | `~/.config/waybar/launch_waybar.sh` (replaces the running instance) |
| mako | `makoctl reload` |
| kitty | new windows pick it up; Ctrl+Shift+F5 reloads an open one |
| helix | `:config-reload` in the running instance; it reads its config once at startup, so a theme or keybinding change is invisible until then |
| zellij | config is read at session start; a running session keeps what it had, and a layout only applies to a session started with it |
| btop, rofi, cava | restart the application |
| GTK | restart the application; there is no live reload, and a running application keeps the palette it started with |
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
`config/sway/.claude/`, `config/cava/config1`, and `config/gtk-3.0/bookmarks`
— the GTK file chooser's sidebar, which GTK rewrites and which holds paths
that exist only on this machine. These still exist on disk. Do not resurrect
them, and do not assume a file's presence on disk means it is tracked.

The reverse trap is worse, because it is silent. `grep` in this shell is a
function wrapping `ugrep`, which reads `.gitignore` when it recurses from the
repository root. `grep -r pattern .` therefore skips every ignored file and
reports a clean tree while the string is still sitting in a `.bak-*` file.
Naming a directory (`grep -r pattern config/`) or using `command grep` reads
them; `git grep` is the right tool when the question really is about tracked
content. Decide which of the two you are asking before believing the answer.

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
