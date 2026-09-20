# .files

> This repository was vibed.
>
> I like a riced system as much as the next person, but the nine tools in here
> speak nine different config dialects, and I do not have the patience to learn
> all of them just to use my own computer. Most of this was written with an LLM
> — including this disclaimer (⌒_⌒;) — and kept once it looked right and
> stopped erroring.
>
> It work on my machine

Personal configuration for a Wayland desktop, themed to
[oxocarbon](https://github.com/nyoom-engineering/oxocarbon) — IBM Carbon's
dark palette on a neutral grey ground.

![Oxocarbon palette](docs/palette.svg)

The real files live in this repository. `~/.config` and `$HOME` hold symlinks
pointing back into it, created by `install.sh`.

## Screenshots

The bare desktop, and a session with a few of the themed applications open:

![Bare desktop](docs/screenshot_desktop.png)
![Themed applications](docs/screenshot_apps.png)

## Applications

| Tool | What is configured |
|------|--------------------|
| [sway](https://swaywm.org) | Three-monitor layout with per-monitor workspace banks, Dvorak input, 3px borders and 5px gaps with smart borders and gaps, media and brightness keys, region screenshots via grim and slurp, and a resize mode with an on-screen hint. Palette is pulled in with `include oxocarbon.txt`. |
| [waybar](https://github.com/Alexays/Waybar) | Two bars: a full one on the centre monitor and a workspaces-only bar on the side monitors, both bottom-anchored. Adds custom modules for AMD GPU load, VRAM and temperature, a cava audio visualiser, and battery levels for connected wireless peripherals. |
| [rofi](https://github.com/davatorium/rofi) | Application launcher and power menu. Both themes import one shared palette from `colors.rasi`, so the colours are defined in a single place. |
| [kitty](https://sw.kovidgoyal.net/kitty/) | Oxocarbon colours, JetBrains Mono Nerd Font at 12pt, beam cursor, 95% background opacity. |
| [helix](https://helix-editor.com) | Oxocarbon theme, shipped locally in `themes/` rather than relied on from upstream. C# language configuration. |
| [btop](https://github.com/aristocratos/btop) | Oxocarbon theme with gradient ramps for the CPU, memory and temperature meters. |
| [cava](https://github.com/karlstav/cava) | Eight-stop oxocarbon gradient running cool to hot, plus GLSL shaders for the OpenGL output. |
| [mako](https://github.com/emersion/mako) | Notification daemon. Border colours follow sway's window colours — blue normally, magenta when urgent, grey for low priority. |
| zsh | The `headline` prompt theme, rbenv, and a large set of terminfo-driven key bindings so Home, End, Delete, word-skip and word-delete behave consistently across terminals. |

### Workspace layout

Workspaces are namespaced per monitor — `11`–`19` on the left, `21`–`29` on
the centre, `31`–`39` on the right — so each monitor owns an independent set
of nine. `sway/ws.sh` maps <kbd>Mod</kbd>+<kbd>1..9</kbd> onto whichever bank
belongs to the focused output, and waybar relabels them back to `1`–`9` for
display.

## Colour scheme

Oxocarbon, defined once per tool in a dedicated palette file:

| Tool | Palette lives in |
|------|------------------|
| sway | `config/sway/oxocarbon.txt` |
| kitty | `config/kitty/oxocarbon.conf` |
| rofi | `config/rofi/colors.rasi` |
| btop | `config/btop/themes/oxocarbon.theme` |
| helix | `config/helix/themes/oxocarbon.toml` |
| cava | `config/cava/config` |
| mako | `config/mako/config` |

| Role | Hex | | Accent | Hex |
|------|-----|-|--------|-----|
| base | `#161616` | | blue | `#33b1ff` |
| mantle | `#0f0f0f` | | lightblue | `#82cfff` |
| surface | `#262626` | | cyan | `#3ddbd9` |
| overlay | `#393939` | | teal | `#08bdba` |
| muted | `#525252` | | green | `#42be65` |
| text | `#dde1e6` | | yellow | `#d2a106` |
| bright | `#f2f4f8` | | brightyellow | `#f1c21b` |
| | | | magenta | `#ee5396` |
| | | | pink | `#ff7eb6` |
| | | | purple | `#be95ff` |

One deliberate departure from upstream: oxocarbon has no yellow and parks
Carbon's light blue in terminal slot 3. Here slot 3 carries Carbon yellow-40
and yellow-30 instead, so warnings, `ls` output and diffs read as yellow. The
light blue stays reachable as `lightblue`.

GitHub renders colour swatches for backticked hex codes in issues, pull
requests and discussions, but not in README files — hence the SVG above.

## Fonts

| Font | Used by |
|------|---------|
| JetBrains Mono Nerd Font | kitty, rofi |
| Iosevka Nerd Font | waybar, mako |
| Roboto | sway window titles |

Two monospace families rather than one is not a decision so much as an
accident. See [TODO](#todo).

## Layout

| Path | Links to | Contents |
|------|----------|----------|
| `config/` | `~/.config/<name>` | `btop` `cava` `helix` `kitty` `mako` `rofi` `sway` `waybar` |
| `home/` | `~/<name>` | `.zshrc` `.zprofile` `.zsh/` |

zsh reads from `$HOME` rather than `~/.config`, which is why it sits in
`home/` instead of alongside the rest.

Directories are linked whole rather than file by file. That keeps the number
of links small, means a new file inside a configuration directory is tracked
without touching `install.sh`, and avoids the usual symlink hazard: an
application that saves settings by writing a temporary file and renaming it
over the original would replace a file-level symlink with a real file and
silently stop updating the repository. btop rewrites its own config file on
exit, so it is exactly the kind of application this guards against. With the
directory linked instead, the file it rewrites is the real one in here.

## Installing

    git clone git@github.com:MalumAtire832/DotFiles.git ~/.files
    ~/.files/install.sh

`install.sh` is idempotent. A target that is already the right symlink is left
alone; anything real found in the way is moved to `<path>.backup-<timestamp>`
rather than overwritten. Re-run it after adding a directory.

### Requirements

Beyond the nine applications above:

| Need | For |
|------|-----|
| `grim`, `slurp`, `wl-clipboard` | screenshots |
| `playerctl`, `pactl` | media keys, waybar's mpris and audio modules |
| `light` | brightness keys |
| `upower` | wireless peripheral battery levels |
| `jq`, `awk` | waybar scripts |
| `bluetoothctl` | device group in waybar |
| `rbenv` | zsh startup |
| JetBrains Mono Nerd Font, Iosevka Nerd Font, Roboto | see [Fonts](#fonts) |

The GPU modules read AMD `amdgpu` sysfs paths and pick the discrete card by
VRAM size. They will report nothing on non-AMD hardware.

Hardware specifics that will need editing on another machine: the output
names `DP-1`, `DP-2` and `HDMI-A-1`, and their resolutions and rotations, in
`config/sway/config`.

## Adding a tool

Move its directory into `config/` and re-run `install.sh`. Nothing else needs
changing — `.gitignore` excludes specific known files rather than everything
by default.

## Wallpapers

`config/sway/wallpapers/` holds the backgrounds, named
`wallpaper_<output>_<n>` so a rotation script has something predictable to
walk. Only the centre output uses an image; the side monitors are painted
with `$surface`.

Images are downscaled to the output they are shown on before being committed.
The current one went from 22016x12288 and 13 MB to 3870x2160 and 385 KB with
no visible difference on a 3840x2160 display, which also spares sway decoding
a 270-megapixel progressive JPEG at every startup.

## TODO

- Settle on one monospace family. kitty and rofi use JetBrains Mono, waybar
  and mako use Iosevka; there is no reason for both.
- Remove the `swaylock.sh` binding from `sway/config`, or write the script.
  Locking is disabled, so the binding currently points at nothing.
- `config/sway/theme` is an empty file that nothing reads.

## Uninstalling

Remove the symlink and move the real directory back:

    rm ~/.config/sway
    mv ~/.files/config/sway ~/.config/sway
