# Cross-platform install

Date: 2026-09-21

## Problem

`install.sh` is written for one machine: a Fedora Wayland desktop. It breaks on
macOS in two independent ways.

**It cannot run.** Line 28 calls `realpath --relative-to=`, which is GNU
coreutils only and fails outright on BSD. Line 17 calls `readlink -f`, which
happens to work on macOS 15 but is absent on older BSD userlands.

**It links the wrong things.** Every directory in `config/` is linked
unconditionally, so a Mac gets `~/.config/sway`, `~/.config/waybar`,
`~/.config/rofi`, `~/.config/mako` and `~/.config/cava` — configuration for a
compositor, a Wayland bar, a Wayland launcher and a Wayland notification daemon
that cannot run there.

Separately, the repository has no executable notion of its own dependencies.
`README.md` lists them in a table for a human to act on.

## Goals

- `install.sh` runs correctly on Fedora and on an M2 MacBook.
- It detects the platform and links only what belongs there.
- It installs missing packages through the platform's package manager: `dnf` on
  Fedora, Homebrew on macOS (assumed present).
- Dependencies live in one declarative place, not prose.
- A re-run on a configured machine stays as cheap and side-effect-free as today.

## Non-goals

- A `zellij` configuration. It is wanted, but it does not exist in the
  repository yet and writing one is a separate piece of work. This change adds
  it to the README TODO list only.
- `kitty` on macOS. It would run there, but the laptop uses a different
  terminal. It stays Fedora-only.
- Bootstrapping Homebrew itself. Its absence is an error with instructions, not
  something the script fixes.
- Support for distributions other than Fedora. The design makes adding one
  cheap; it does not add one.

## Platform detection

`uname -s` separates Darwin from Linux. On Linux the script sources
`/etc/os-release` and takes `$ID`.

Platform identifiers are distro-level — `fedora`, `macos` — rather than
family-level. Package names are distro-specific: `rofi-wayland` means nothing
to `apt`, and `light` is packaged under three different names across
distributions. A `linux` identifier would have to be subdivided the first time a
second distribution appeared. Adding Arch later is then a manifest field and one
package-manager mapping, not a redesign.

An unrecognised platform is a hard error naming what is supported. A missing
package manager is a hard error too; on macOS it prints the Homebrew
installation URL.

## The manifest

`manifest.sh` sits beside `install.sh` and is sourced by it. It contains nothing
but `tool` invocations:

```sh
# tool <name> --platforms "<ids>"  [--config <dir>]  [--home "<entries>"]
#             [--dnf "<pkgs>"] [--brew "<pkgs>"] [--cask "<casks>"]
#             [--tap "<taps>"] [--copr "<repos>"] [--post "<cmd>"]

tool zsh    --platforms "fedora macos" --home ".zshrc .zprofile .zsh" \
            --dnf "zsh rbenv" --brew "zsh rbenv"
tool helix  --platforms "fedora macos" --config helix --dnf "helix" --brew "helix"
tool btop   --platforms "fedora macos" --config btop  --dnf "btop"  --brew "btop"
tool kitty  --platforms "fedora"       --config kitty --dnf "kitty"
tool sway   --platforms "fedora"       --config sway \
            --dnf "sway swaybg grim slurp wl-clipboard playerctl light"
tool waybar --platforms "fedora"       --config waybar --dnf "waybar jq gawk upower"
tool rofi   --platforms "fedora"       --config rofi  --dnf "rofi-wayland"
tool mako   --platforms "fedora"       --config mako  --dnf "mako"
tool cava   --platforms "fedora"       --config cava  --dnf "cava"
```

`tool()` is defined in `install.sh` and only records its arguments. The manifest
executes nothing else.

### Why shell rather than JSON

JSON was the starting proposal. It needs a parser, and the only parser worth
using is `jq` — which is itself a package the manifest would declare, so the
script would have to install its own parser before it could read what to
install. `python3` is not an escape hatch: macOS 15 ships a stub at
`/usr/bin/python3` that opens an Xcode Command Line Tools prompt instead of
running. `perl` is on macOS but not guaranteed on a minimal Fedora. Only `sh`
and `awk` are certain on both.

Shell is the format both platforms parse natively. Sourcing a file that
`install.sh` ships alongside itself is not a new trust boundary — the user is
already running `install.sh` as themselves. The cost is real and accepted: the
manifest is code, not inert data, and no non-shell tool can ever read it.

Alternatives weighed and rejected: an INI-style file (inert, but hand-rolling
and maintaining a parser in POSIX shell is more bug surface than the five lines
shell-sourcing costs) and TSV columns (least parsing code, but every future
field widens every line).

### Why tool-centric rather than platform-centric

A platform-centric manifest — a block per platform listing its configs and
packages — writes every cross-platform tool into every platform block, where the
copies drift. `AGENTS.md` already documents two instances of exactly that
failure mode in this repository: monitor names duplicated across three files and
workspace maps across four.

Declaring each tool once, with the platforms it applies to and its per-manager
package names, removes the duplication and encodes why each package is wanted:
`grim` and `slurp` are visibly sway's dependencies, so a platform without sway
gets neither.

### Package names are unverified

The package names above are indicative. During implementation each is checked
with `dnf provides` or `brew info`. The Fedora column cannot be verified from
the macOS machine this work is being done on; any name that cannot be confirmed
is flagged for the user rather than shipped as a guess.

Fonts are deliberately absent from the list above for the same reason: JetBrains
Mono Nerd Font and Iosevka Nerd Font are Homebrew casks on macOS and, on Fedora,
may require a COPR. The `--cask`, `--tap` and `--copr` fields exist in the DSL to
express this; populating them is part of implementation, subject to the same
verification rule.

## Linking

Two GNU-isms are removed.

`realpath --relative-to=` is replaced by **absolute symlink targets**. Existing
relative links on the Fedora machine resolve to the same paths, so they report
`ok` and are not recreated. No churn.

`readlink -f` is replaced by a POSIX `resolve()` built on `cd` and `pwd -P`,
which behaves identically on both platforms and does not depend on a recent BSD
coreutils.

The remaining tool usage — `ln -s --`, `mv --`, `mkdir -p --`, `date +%...` —
was verified working on macOS 15.1.1's BSD tools.

The script stays compatible with bash 3.2, which is what Apple ships at
`/bin/bash`. Specifically, no associative arrays. This means the script runs on
a stock Mac without Homebrew's bash having been installed first.

## Execution flow

1. Detect the platform. Verify its package manager exists.
2. Source `manifest.sh`. Keep the tools whose `--platforms` includes this
   platform.
3. Warn about any `config/*` directory, and any `home/.*` entry, that no
   manifest entry mentions, printing `unassigned: <name> (not linked)`.
   Adding `config/zellij/` later and forgetting to declare it is then loud
   rather than silent.
4. For each enabled tool, in manifest order:
   1. Query what is already installed — `rpm -q` on Fedora, or `brew list
      --formula` and `brew list --cask` on macOS, each queried once and
      cached. All are local, fast and need no privileges.
   2. If nothing is missing, invoke no package manager. A re-run on a configured
      machine therefore requests no sudo and touches no network, preserving the
      cheap-idempotent-check property `AGENTS.md` documents.
   3. If something is missing, run one install call for that tool's missing set.
      One transaction per tool, not per package.
   4. On failure: record the error, **skip that tool's symlinks**, continue to
      the next tool. A tool whose packages will not install should not have its
      configuration linked into place.
   5. On success: run `--post` if present, then link the tool's `--config`
      directory and `--home` entries.
5. Print a summary of linked, ok, and skipped tools, including each failure's
   error text and a note that a re-run retries only what is missing.
6. Exit non-zero if any tool failed.

### Failure of an already-linked tool

If a tool's packages fail but its configuration was linked by an earlier
successful run, the existing link is left alone. Tearing down a working link
because of a transient network error would be worse than the failure being
reported.

### `--dry-run`

A `--dry-run` flag prints what would be installed and linked and changes
nothing. The Fedora path cannot be tested from the macOS machine this is
developed on; the flag is what makes it validatable there before a real run.

## Shell configuration

`.zshrc` and `.zprofile` are single files symlinked onto both machines, so
platform differences are runtime checks, not install-time decisions.

- `export XDG_CURRENT_DESKTOP=sway` becomes Linux-only. On macOS it is a false
  statement about the session.
- `eval "$(rbenv init - zsh)"` in `.zshrc`, and the same call in `.zprofile`,
  become conditional on `command -v rbenv`. As written they error on startup on
  any machine without rbenv, including the MacBook.
- `.zprofile` gains a macOS-guarded `eval "$(/opt/homebrew/bin/brew shellenv)"`
  so `/opt/homebrew/bin` is on `PATH` in login shells.
- `zstyle :compinstall filename '/home/malum/.zshrc'` hardcodes a path that
  exists on neither machine. Corrected to `$HOME/.zshrc`.

## Documentation

`README.md`:

- A Platforms section stating what each OS receives.
- Installing updated for the two platforms.
- The Requirements table points at `manifest.sh` as the source of truth.
- `zellij` added to TODO.

`AGENTS.md`:

- `manifest.sh` added to the Layout block.
- "Adding a tool" rewritten. Adding a tool now requires a manifest line. This
  contradicts the current text — "Nothing else is needed" — and the contradiction
  must be stated plainly rather than left for a future reader to trip over.
- The Verifying table's note that `./install.sh` "changes nothing" is qualified:
  it still changes nothing when every package is present, which is the normal
  case, but it is no longer unconditionally true.

## Verification

- `bash -n install.sh manifest.sh`.
- `shellcheck` on both, if available.
- A real run on the MacBook: `helix`, `btop` and the zsh entries link;
  `sway`, `waybar`, `rofi`, `mako`, `cava` and `kitty` are skipped.
- A second run on the MacBook reports `ok` throughout, invokes no package
  manager, and requests no privileges.
- `timeout 20 zsh -i -c 'echo ok'` after the `.zshrc` changes, on macOS.
- `--dry-run` output reviewed for the Fedora path, which cannot otherwise be
  exercised from here.
