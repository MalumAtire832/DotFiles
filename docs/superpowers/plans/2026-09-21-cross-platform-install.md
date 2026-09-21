# Cross-Platform Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `install.sh` detect its platform, install only the packages that platform needs, and link only the configuration that belongs there — on both Fedora and an M2 MacBook.

**Architecture:** `manifest.sh` declares each tool once as a `tool <name> --platforms ... --dnf ... --brew ...` line and is sourced by `install.sh`, which defines `tool()` to record the arguments into parallel indexed arrays. `install.sh` detects the platform from `uname -s` plus `/etc/os-release`, filters the manifest to that platform, and for each tool installs missing packages then links its config. A tool whose install fails is reported and skipped, and the run continues.

**Tech Stack:** POSIX-leaning bash, constrained to bash 3.2 (Apple's `/bin/bash`) — indexed arrays are fine, `declare -A` is not. No external dependencies: no `jq`, no `bats`, no GNU coreutils. Tests are a hand-rolled runner in `tests/`.

---

## Deviation from the spec — read before starting

The spec's manifest DSL lists nine flags. This plan implements seven and defers two:

- **`--tap` is dropped.** Its stated purpose was `homebrew/cask-fonts`, which Homebrew merged into core in 2024. `brew info --cask font-jetbrains-mono-nerd-font` was verified to resolve on this machine with nothing tapped. The flag would be dead code.
- **`--copr` is deferred.** It cannot be meaningfully tested without a real COPR name, and no tool needs one yet. Add it when the Fedora font entry lands.

`tool()` rejects unknown flags, so a manifest line using either fails loudly rather than being silently ignored.

## Package name verification status

**macOS — all verified on this machine** via `brew info`:
`helix`, `btop`, `zsh`, `rbenv`, `jq` (formulae). Casks `font-jetbrains-mono-nerd-font`, `font-iosevka-nerd-font`, `font-roboto` all resolve, but no macOS tool needs a font — the Mac runs helix in an existing terminal.

**Fedora — NOT verified.** Cannot be checked from macOS. Task 8 ships the names below and Task 11 verifies them on the Fedora machine before trusting them:
`sway swaybg grim slurp wl-clipboard playerctl light waybar jq gawk upower bluez rofi-wayland mako cava kitty btop helix zsh rbenv`

**Fonts are deliberately absent from the manifest.** The Nerd Font packaging on Fedora is uncertain (`jetbrains-mono-fonts` is not the Nerd Font patch, and the Nerd Font variants may need a COPR). Task 10 adds this to the README TODO rather than guessing.

## File structure

| File | Responsibility |
|------|----------------|
| `install.sh` (modify) | Platform detection, manifest loading, package install, linking, summary. Sourceable with `DOTFILES_LIB_ONLY=1` so tests can call its functions. |
| `manifest.sh` (create) | Data only. Nothing but `tool` lines and comments. |
| `tests/install_test.sh` (create) | Dependency-free test runner and all tests. |
| `home/.zshrc` (modify) | Runtime platform guards. |
| `home/.zprofile` (modify) | Runtime platform guards, Homebrew `shellenv`. |
| `README.md`, `AGENTS.md` (modify) | Documentation. |

---

### Task 1: Test harness and `resolve()`

Replaces `readlink -f`, which is GNU-first and absent from older BSD userlands.

**Files:**
- Create: `tests/install_test.sh`
- Modify: `install.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/install_test.sh`:

```bash
#!/usr/bin/env bash
#
# Dependency-free test runner for install.sh.
#
# Usage: tests/install_test.sh [name-substring]
#
# install.sh is sourced with DOTFILES_LIB_ONLY=1, which defines its functions
# without running main. install.sh sets -e; we turn it back off, because a
# failed assertion must record a failure and keep going rather than kill the run.

set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
filter=${1:-}

DOTFILES_LIB_ONLY=1 . "$repo_root/install.sh"
set +e

tests_run=0
tests_failed=0
tests_skipped=0
skipped_this_test=0
current_test=""
sandboxes=()

cleanup() {
    local s
    for s in ${sandboxes+"${sandboxes[@]}"}; do
        [ -n "$s" ] && rm -rf -- "$s"
    done
}
trap cleanup EXIT

sandbox() {
    local s
    s=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test.XXXXXX")
    sandboxes+=("$s")
    printf '%s\n' "$s"
}

fail() {
    tests_failed=$((tests_failed + 1))
    printf '  FAIL %s\n       %s\n' "$current_test" "$1"
}

assert_eq() {
    # assert_eq <actual> <expected> <description>
    if [ "$1" != "$2" ]; then
        fail "$3: expected [$2], got [$1]"
    fi
}

assert_contains() {
    # assert_contains <haystack> <needle> <description>
    case "$1" in
        *"$2"*) ;;
        *) fail "$3: expected to find [$2] in [$1]" ;;
    esac
}

assert_ok() {
    # assert_ok <status> <description>
    if [ "$1" != 0 ]; then
        fail "$2: expected success, got status $1"
    fi
}

assert_fails() {
    # assert_fails <status> <description>
    if [ "$1" = 0 ]; then
        fail "$2: expected failure, got success"
    fi
}

skip() {
    # skip <reason> — declare that this test cannot run on this machine.
    #
    # Skipped tests are counted separately and never reported as "ok". A test
    # that did not run but prints a pass is false confidence about coverage,
    # which is exactly how a real bug reached review earlier in this plan.
    tests_skipped=$((tests_skipped + 1))
    skipped_this_test=1
    printf '  skip %s (%s)\n' "$current_test" "$1"
}

run_test() {
    case "$1" in
        *"$filter"*) ;;
        *) return 0 ;;
    esac
    current_test=$1
    skipped_this_test=0
    local before=$tests_failed
    "$1"
    # A test that called skip and then failed an assertion anyway is a
    # test-authoring bug (a missing return after skip). Report it as a
    # failure: a failure that appeared in no counted test reads as noise.
    if [ "$skipped_this_test" = 1 ] && [ "$tests_failed" = "$before" ]; then
        return 0
    fi
    tests_run=$((tests_run + 1))
    if [ "$tests_failed" = "$before" ]; then
        printf '  ok   %s\n' "$1"
    fi
}

# --------------------------------------------------------------------------
# resolve()
# --------------------------------------------------------------------------

test_resolve_directory_is_absolute_and_physical() {
    local box
    box=$(sandbox)
    mkdir -p "$box/real"
    assert_eq "$(resolve "$box/real")" "$(cd "$box/real" && pwd -P)" "directory"
}

test_resolve_follows_a_symlinked_directory() {
    local box
    box=$(sandbox)
    mkdir -p "$box/real"
    ln -s -- "$box/real" "$box/link"
    assert_eq "$(resolve "$box/link")" "$(resolve "$box/real")" "symlinked dir"
}

test_resolve_handles_a_plain_file() {
    local box
    box=$(sandbox)
    : > "$box/file"
    assert_eq "$(resolve "$box/file")" "$(cd "$box" && pwd -P)/file" "plain file"
}

test_resolve_handles_a_nonexistent_leaf() {
    local box
    box=$(sandbox)
    assert_eq "$(resolve "$box/missing")" "$(cd "$box" && pwd -P)/missing" "missing leaf"
}

test_resolve_follows_a_symlink_to_a_file() {
    # The case link() actually hits for home/.zshrc and home/.zprofile. A
    # symlink to a file must resolve to its target, not to its own path.
    local box
    box=$(sandbox)
    mkdir -p "$box/repo"
    : > "$box/repo/.zshrc"
    ln -s -- "$box/repo/.zshrc" "$box/link"
    assert_eq "$(resolve "$box/link")" "$(resolve "$box/repo/.zshrc")" "symlink to file"
}

test_resolve_follows_a_relative_symlink() {
    local box
    box=$(sandbox)
    mkdir -p "$box/repo"
    : > "$box/repo/.zshrc"
    ln -s -- "repo/.zshrc" "$box/link"
    assert_eq "$(resolve "$box/link")" "$(resolve "$box/repo/.zshrc")" "relative symlink"
}

test_resolve_fails_on_a_missing_parent() {
    # readlink -f errors here. Returning a fabricated path with status 0 would
    # let a wrong value flow into a backup-and-relink decision.
    local box out status
    box=$(sandbox)
    out=$(resolve "$box/absent/leaf" 2>/dev/null)
    status=$?
    assert_fails $status "missing parent reports failure"
    assert_eq "$out" "" "missing parent prints nothing"
}

test_resolve_detects_a_symlink_loop() {
    local box status
    box=$(sandbox)
    ln -s -- "$box/b" "$box/a"
    ln -s -- "$box/a" "$box/b"
    resolve "$box/a" >/dev/null 2>&1
    status=$?
    assert_fails $status "symlink loop reports failure"
}

run_test test_resolve_directory_is_absolute_and_physical
run_test test_resolve_follows_a_symlinked_directory
run_test test_resolve_handles_a_plain_file
run_test test_resolve_handles_a_nonexistent_leaf
run_test test_resolve_follows_a_symlink_to_a_file
run_test test_resolve_follows_a_relative_symlink
run_test test_resolve_fails_on_a_missing_parent
run_test test_resolve_detects_a_symlink_loop

printf '\n%d test(s), %d failure(s), %d skipped\n' \
    "$tests_run" "$tests_failed" "$tests_skipped"

# A mistyped filter would otherwise print "0 test(s), 0 failure(s)" and exit 0,
# which reads exactly like a pass.
if [ -n "$filter" ] && [ "$tests_run" = 0 ] && [ "$tests_skipped" = 0 ]; then
    printf 'No test matched filter [%s]\n' "$filter" >&2
    exit 1
fi

[ "$tests_failed" = 0 ]
```

Make it executable:

```bash
chmod +x tests/install_test.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `tests/install_test.sh`
Expected: FAIL. `install.sh` has no `DOTFILES_LIB_ONLY` guard, so sourcing it runs the whole installer; and `resolve` is undefined. The error will mention `resolve: command not found` or the script will link files into your real `$HOME`.

**If it starts linking into your real `$HOME`, stop and complete Step 3 first.** Sourcing an unguarded `install.sh` executes it.

- [ ] **Step 3: Add `resolve()` and the library guard to `install.sh`**

Replace the whole of `install.sh` with:

```bash
#!/usr/bin/env bash
#
# Link this repository's configuration into place, installing what it needs.
#
# The platform is detected, manifest.sh is consulted for what that platform
# should receive, missing packages are installed, and the configuration is
# linked. Idempotent: an already-correct symlink is left alone, anything real
# found at a target path is moved to <path>.backup-<timestamp>, and no package
# manager is invoked when nothing is missing.
#
# Usage: install.sh [--dry-run] [--help]
#
# Sourcing with DOTFILES_LIB_ONLY=1 defines the functions without running.

set -euo pipefail

files_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
stamp=$(date +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------------------
# Portability helpers
#
# Written for bash 3.2, which is what Apple ships at /bin/bash: indexed arrays
# are available, associative arrays are not. GNU-only tools are avoided —
# `readlink -f` and `realpath --relative-to=` are both absent or different on
# BSD userlands.
# ---------------------------------------------------------------------------

resolve() {
    # Print the absolute, symlink-free path of $1. Stands in for `readlink -f`.
    #
    # The symlink chain is walked explicitly. Testing `-d` alone is not enough:
    # `-d` follows a symlink to a directory, but a symlink to a *file* would
    # fall through to the leaf branch, which resolves only the containing
    # directory and reattaches the link's own name — returning the link's path
    # rather than its target. home/.zshrc and home/.zprofile are exactly that
    # case, so link() would judge them wrong on every run and relink them.
    #
    # Plain `readlink` with no flags is POSIX and present on both userlands;
    # only `readlink -f` is the GNU-ism being avoided.
    local path=$1 target parent hops=0

    while [ -L "$path" ]; do
        hops=$((hops + 1))
        if [ "$hops" -gt 40 ]; then
            printf 'resolve: too many levels of symbolic links: %s\n' "$1" >&2
            return 1
        fi
        target=$(readlink -- "$path") || return 1
        case "$target" in
            /*) path=$target ;;
            *)  path="$(dirname -- "$path")/$target" ;;
        esac
    done

    if [ -d "$path" ]; then
        (cd -- "$path" && pwd -P) || return 1
    else
        # Assigning the substitution separately so a failing cd is caught. As
        # an argument to printf its status is discarded and set -e never fires,
        # which would return a fabricated path with status 0.
        parent=$(cd -- "$(dirname -- "$path")" && pwd -P) || return 1
        printf '%s/%s\n' "$parent" "$(basename -- "$path")"
    fi
}

main() {
    printf 'not implemented yet\n'
}

if [ "${DOTFILES_LIB_ONLY:-0}" != 1 ]; then
    main "$@"
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/install_test.sh`
Expected: `8 test(s), 0 failure(s), 0 skipped`, exit 0.

- [ ] **Step 5: Verify the script still parses and is not executable-broken**

Run: `bash -n install.sh && bash -n tests/install_test.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

- [ ] **Step 6: Commit**

```bash
git add install.sh tests/install_test.sh
git commit -m "Replace readlink -f with a portable resolve()

BSD userlands did not carry readlink -f until recently, so the symlink
comparison in install.sh could not run on macOS. resolve() does the same
job with cd and pwd -P, which are POSIX.

install.sh now defines its functions without running when sourced with
DOTFILES_LIB_ONLY=1, so the new test runner can exercise them directly."
```

---

### Task 2: `os_release_id()` and `detect_platform()`

Platform detection is split in two: one function reads an os-release file, one
decides the platform. The split exists for testability — `detect_platform`
takes the Darwin branch on macOS and never reaches the Linux code, so the
os-release parsing would otherwise be untestable on the machine this is being
written on, which is exactly the half that has to work on Fedora.

**Files:**
- Modify: `install.sh`
- Modify: `tests/install_test.sh`

- [ ] **Step 1: Write the failing tests**

In `tests/install_test.sh`, insert before the final `printf '\n%d test(s)` line:

```bash
# --------------------------------------------------------------------------
# os_release_id()
#
# These take a fixture path, so they exercise the Linux parsing on any
# platform. A test that can only run on Fedora is a test this machine cannot
# run at all.
# --------------------------------------------------------------------------

test_os_release_id_reads_an_unquoted_id() {
    # Fedora writes ID=fedora with no quotes.
    local box
    box=$(sandbox)
    printf 'NAME=Fedora Linux\nID=fedora\n' > "$box/os-release"
    assert_eq "$(os_release_id "$box/os-release")" "fedora" "unquoted ID"
}

test_os_release_id_reads_a_quoted_id() {
    # Debian and others write ID="debian". Both forms occur in the wild.
    local box
    box=$(sandbox)
    printf 'NAME="Debian GNU/Linux"\nID="debian"\n' > "$box/os-release"
    assert_eq "$(os_release_id "$box/os-release")" "debian" "quoted ID"
}

test_os_release_id_reports_unknown_without_an_id() {
    local box
    box=$(sandbox)
    printf 'NAME=Something\n' > "$box/os-release"
    assert_eq "$(os_release_id "$box/os-release")" "unknown" "no ID line"
}

test_os_release_id_reports_unknown_for_an_empty_id() {
    local box
    box=$(sandbox)
    printf 'ID=""\n' > "$box/os-release"
    assert_eq "$(os_release_id "$box/os-release")" "unknown" "empty ID"
}

test_os_release_id_reports_unknown_for_a_missing_file() {
    local box
    box=$(sandbox)
    assert_eq "$(os_release_id "$box/absent")" "unknown" "missing file"
}

test_os_release_id_does_not_leak_variables() {
    # os-release defines ID, NAME and VERSION. Sourcing it in the caller's
    # shell would clobber them, so it is sourced in a subshell.
    #
    # This test takes a fixture rather than relying on /etc/os-release, so it
    # genuinely exercises the sourcing path on macOS too. Asserting against
    # the real file would pass trivially on Darwin, where this code never runs.
    local box ID NAME VERSION
    box=$(sandbox)
    printf 'NAME=Fedora Linux\nID=fedora\nVERSION=41\n' > "$box/os-release"
    ID="sentinel"
    NAME="sentinel"
    VERSION="sentinel"
    os_release_id "$box/os-release" >/dev/null
    assert_eq "$ID" "sentinel" "ID not leaked"
    assert_eq "$NAME" "sentinel" "NAME not leaked"
    assert_eq "$VERSION" "sentinel" "VERSION not leaked"
}

# --------------------------------------------------------------------------
# detect_platform()
# --------------------------------------------------------------------------

test_detect_platform_honours_the_override() {
    assert_eq "$(DOTFILES_PLATFORM=fedora detect_platform)" "fedora" "override"
}

test_detect_platform_trims_the_override() {
    # A value pasted from shell history can carry a trailing space. Tasks
    # downstream match it against a fixed list, where " fedora" matches
    # nothing and the failure would be reported far from its cause.
    assert_eq "$(DOTFILES_PLATFORM='  fedora  ' detect_platform)" "fedora" "trimmed"
}

test_detect_platform_ignores_a_whitespace_only_override() {
    # Whitespace-only is a typo, not a platform. It must fall through to real
    # detection rather than being used as the platform name.
    assert_eq "$(DOTFILES_PLATFORM='   ' detect_platform)" \
        "$(detect_platform)" "whitespace override ignored"
}

test_detect_platform_reports_macos_on_darwin() {
    if [ "$(uname -s)" != Darwin ]; then
        skip "not Darwin"
        return 0
    fi
    assert_eq "$(detect_platform)" "macos" "darwin"
}

test_detect_platform_reads_os_release_id_on_linux() {
    if [ "$(uname -s)" != Linux ]; then
        skip "not Linux"
        return 0
    fi
    local expected
    expected=$(os_release_id /etc/os-release)
    assert_eq "$(detect_platform)" "$expected" "linux"
}

run_test test_os_release_id_reads_an_unquoted_id
run_test test_os_release_id_reads_a_quoted_id
run_test test_os_release_id_reports_unknown_without_an_id
run_test test_os_release_id_reports_unknown_for_an_empty_id
run_test test_os_release_id_reports_unknown_for_a_missing_file
run_test test_os_release_id_does_not_leak_variables
run_test test_detect_platform_honours_the_override
run_test test_detect_platform_trims_the_override
run_test test_detect_platform_ignores_a_whitespace_only_override
run_test test_detect_platform_reports_macos_on_darwin
run_test test_detect_platform_reads_os_release_id_on_linux
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/install_test.sh os_release_id`
Expected: FAIL with `os_release_id: command not found`.

Then run: `tests/install_test.sh detect_platform`
Expected: FAIL with `detect_platform: command not found`.

- [ ] **Step 3: Implement both functions**

In `install.sh`, insert after `resolve()`:

```bash
os_release_id() {
    # Print the ID field of an os-release file — $1, or /etc/os-release — or
    # "unknown" when the file is unreadable or names no ID.
    #
    # Taking the path as an argument is what makes this testable from macOS,
    # where detect_platform never reaches this code.
    #
    # The file is sourced, as freedesktop.org's own os-release specification
    # recommends, which does mean its values are executed as shell. It is
    # root-owned on a normal system; on one where it is not, the reader has
    # larger problems than this script.
    local file=${1:-/etc/os-release}

    if [ ! -r "$file" ]; then
        printf 'unknown\n'
        return 0
    fi

    # In a subshell: os-release defines ID, NAME and VERSION, and sourcing it
    # here would clobber the caller's variables of those names.
    (
        # shellcheck disable=SC1091
        . "$file"
        printf '%s\n' "${ID:-unknown}"
    )
}

detect_platform() {
    # Print this machine's platform identifier: "macos", or the ID field from
    # /etc/os-release on Linux ("fedora").
    #
    # "unknown" covers two different situations — a kernel that is neither
    # Darwin nor Linux, and a Linux whose distribution could not be
    # identified. Callers treat both the same way: refuse to continue.
    #
    # Identifiers are distro-level rather than family-level because package
    # names are distro-specific: rofi-wayland means nothing to apt. Set
    # DOTFILES_PLATFORM to override, which is how the tests reach both paths
    # and how a user dry-runs the other platform's plan.
    local override=${DOTFILES_PLATFORM:-}

    # Trim surrounding whitespace. A value pasted from shell history can carry
    # a trailing space, and " fedora" would match nothing downstream while
    # looking correct in the error message.
    override=${override#"${override%%[![:space:]]*}"}
    override=${override%"${override##*[![:space:]]}"}

    if [ -n "$override" ]; then
        printf '%s\n' "$override"
        return 0
    fi

    case "$(uname -s)" in
        Darwin)
            printf 'macos\n'
            ;;
        Linux)
            os_release_id /etc/os-release
            ;;
        *)
            printf 'unknown\n'
            ;;
    esac
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/install_test.sh`
Expected: `16 test(s), 0 failure(s), 1 skipped` on macOS. The Linux-only platform test is skipped; the six `os_release_id` tests run everywhere because they take a fixture path.

- [ ] **Step 5: Verify against stock bash 3.2**

Run: `bash -n install.sh && bash -n tests/install_test.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

The trim uses `${var#"${var%%[![:space:]]*}"}`, which is POSIX parameter
expansion and works in bash 3.2. Confirm the suite passes under `/bin/bash`
specifically, not whatever `bash` resolves to on `PATH`.

- [ ] **Step 6: Commit**

```bash
git add install.sh tests/install_test.sh
git commit -m "Detect the platform from uname and os-release

Identifiers are distro-level rather than family-level, because package
names are distro-specific and a linux identifier would have to be
subdivided the first time a second distribution appeared.

Reading os-release is a separate function that takes the file path. On
macOS detect_platform takes the Darwin branch and never reaches the
Linux code, so without the split the os-release parsing could not be
tested on the machine this was written on -- and that is the half that
has to work on Fedora. It is sourced in a subshell: os-release defines
ID, NAME and VERSION, which are exactly the names a caller might use.

DOTFILES_PLATFORM is trimmed, and a whitespace-only value falls through
to real detection rather than being taken as a platform name."
```

---

### Task 3: The manifest DSL — `tool()` and `list_contains()`

**Files:**
- Modify: `install.sh`
- Modify: `tests/install_test.sh`

- [ ] **Step 1: Write the failing tests**

In `tests/install_test.sh`, insert before the final `printf '\n%d test(s)` line:

```bash
# --------------------------------------------------------------------------
# list_contains() and tool()
# --------------------------------------------------------------------------

test_list_contains_finds_a_word() {
    list_contains fedora "fedora macos"
    assert_ok $? "present"
}

test_list_contains_rejects_a_missing_word() {
    list_contains arch "fedora macos"
    assert_fails $? "absent"
}

test_list_contains_rejects_a_partial_match() {
    # "fedora" must not match inside "fedora-silverblue".
    list_contains fedora "fedora-silverblue"
    assert_fails $? "partial"
}

test_list_contains_handles_an_empty_list() {
    list_contains fedora ""
    assert_fails $? "empty"
}

test_tool_records_every_field() {
    manifest_reset
    tool btop --platforms "fedora macos" --config btop \
        --dnf "btop" --brew "btop"
    assert_eq "${#tool_names[@]}" "1" "one tool recorded"
    assert_eq "${tool_names[0]}" "btop" "name"
    assert_eq "${tool_platforms[0]}" "fedora macos" "platforms"
    assert_eq "${tool_config[0]}" "btop" "config"
    assert_eq "${tool_dnf[0]}" "btop" "dnf"
    assert_eq "${tool_brew[0]}" "btop" "brew"
    assert_eq "${tool_home[0]}" "" "home defaults empty"
    assert_eq "${tool_cask[0]}" "" "cask defaults empty"
    assert_eq "${tool_post[0]}" "" "post defaults empty"
}

test_tool_records_home_entries_and_post() {
    manifest_reset
    tool zsh --platforms "fedora macos" --home ".zshrc .zprofile .zsh" \
        --dnf "zsh" --post "echo done"
    assert_eq "${tool_home[0]}" ".zshrc .zprofile .zsh" "home"
    assert_eq "${tool_post[0]}" "echo done" "post"
    assert_eq "${tool_config[0]}" "" "config defaults empty"
}

test_tool_records_several_tools_in_order() {
    manifest_reset
    tool a --platforms fedora
    tool b --platforms macos
    assert_eq "${#tool_names[@]}" "2" "two tools"
    assert_eq "${tool_names[0]}" "a" "first"
    assert_eq "${tool_names[1]}" "b" "second"
}

test_tool_rejects_an_unknown_flag() {
    manifest_reset
    local out
    out=$(tool bad --platforms fedora --nonsense x 2>&1)
    assert_fails $? "unknown flag status"
    assert_contains "$out" "unknown option --nonsense" "unknown flag message"
}

test_tool_requires_platforms() {
    manifest_reset
    local out
    out=$(tool bad --config bad 2>&1)
    assert_fails $? "missing platforms status"
    assert_contains "$out" "--platforms is required" "missing platforms message"
}

test_tool_rejects_a_flag_with_no_value() {
    manifest_reset
    local out
    out=$(tool bad --platforms 2>&1)
    assert_fails $? "dangling flag status"
    assert_contains "$out" "--platforms needs a value" "dangling flag message"
}

run_test test_list_contains_finds_a_word
run_test test_list_contains_rejects_a_missing_word
run_test test_list_contains_rejects_a_partial_match
run_test test_list_contains_handles_an_empty_list
run_test test_tool_records_every_field
run_test test_tool_records_home_entries_and_post
run_test test_tool_records_several_tools_in_order
run_test test_tool_rejects_an_unknown_flag
run_test test_tool_requires_platforms
run_test test_tool_rejects_a_flag_with_no_value
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/install_test.sh list_contains`
Expected: FAIL with `list_contains: command not found`.

- [ ] **Step 3: Implement `list_contains()`, `manifest_reset()` and `tool()`**

In `install.sh`, insert after `detect_platform()`:

```bash
# ---------------------------------------------------------------------------
# The manifest
#
# manifest.sh is sourced and contains nothing but `tool` lines. tool() records
# its arguments into parallel indexed arrays — one array per field, sharing an
# index — because bash 3.2 has no associative arrays and this script has to run
# on Apple's /bin/bash.
# ---------------------------------------------------------------------------

tool_names=()
tool_platforms=()
tool_config=()
tool_home=()
tool_dnf=()
tool_brew=()
tool_cask=()
tool_post=()

manifest_reset() {
    tool_names=()
    tool_platforms=()
    tool_config=()
    tool_home=()
    tool_dnf=()
    tool_brew=()
    tool_cask=()
    tool_post=()
}

list_contains() {
    # True when the whole word $1 appears in the space-separated list $2.
    local needle=$1 word
    for word in $2; do
        if [ "$word" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

tool() {
    # tool <name> --platforms "<ids>" [--config <dir>] [--home "<entries>"]
    #             [--dnf "<pkgs>"] [--brew "<pkgs>"] [--cask "<casks>"]
    #             [--post "<command>"]
    #
    # Unknown flags are an error rather than being ignored, so a typo in the
    # manifest surfaces immediately instead of silently dropping a dependency.
    local name=${1:-}
    shift || true

    if [ -z "$name" ]; then
        printf 'manifest: tool needs a name\n' >&2
        return 1
    fi

    local platforms='' config='' home='' dnf='' brew='' cask='' post=''

    while [ $# -gt 0 ]; do
        case $1 in
            --platforms|--config|--home|--dnf|--brew|--cask|--post)
                if [ $# -lt 2 ]; then
                    printf 'manifest: %s needs a value (tool %s)\n' "$1" "$name" >&2
                    return 1
                fi
                case $1 in
                    --platforms) platforms=$2 ;;
                    --config)    config=$2 ;;
                    --home)      home=$2 ;;
                    --dnf)       dnf=$2 ;;
                    --brew)      brew=$2 ;;
                    --cask)      cask=$2 ;;
                    --post)      post=$2 ;;
                esac
                shift 2
                ;;
            *)
                printf 'manifest: unknown option %s (tool %s)\n' "$1" "$name" >&2
                return 1
                ;;
        esac
    done

    if [ -z "$platforms" ]; then
        printf 'manifest: --platforms is required (tool %s)\n' "$name" >&2
        return 1
    fi

    tool_names+=("$name")
    tool_platforms+=("$platforms")
    tool_config+=("$config")
    tool_home+=("$home")
    tool_dnf+=("$dnf")
    tool_brew+=("$brew")
    tool_cask+=("$cask")
    tool_post+=("$post")
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/install_test.sh`
Expected: `26 test(s), 0 failure(s), 1 skipped`.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install_test.sh
git commit -m "Add the manifest DSL

tool() records its arguments into parallel indexed arrays rather than an
associative array, because bash 3.2 is what Apple ships at /bin/bash and
has no associative arrays.

Unknown flags are an error. A manifest typo that was silently ignored
would drop a dependency and only show up as a missing binary later."
```

---

### Task 4: Portable `link()`

**Files:**
- Modify: `install.sh`
- Modify: `tests/install_test.sh`

- [ ] **Step 1: Write the failing tests**

In `tests/install_test.sh`, insert before the final `printf '\n%d test(s)` line:

```bash
# --------------------------------------------------------------------------
# link()
# --------------------------------------------------------------------------

test_link_creates_an_absolute_symlink() {
    local box
    box=$(sandbox)
    mkdir -p "$box/src" "$box/home"
    link "$box/src" "$box/home/target" >/dev/null
    if [ ! -L "$box/home/target" ]; then
        fail "no symlink created"
        return
    fi
    assert_eq "$(readlink "$box/home/target")" "$(resolve "$box/src")" "absolute target"
}

test_link_reports_ok_for_an_existing_correct_link() {
    local box out
    box=$(sandbox)
    mkdir -p "$box/src" "$box/home"
    link "$box/src" "$box/home/target" >/dev/null
    out=$(link "$box/src" "$box/home/target")
    assert_contains "$out" "ok" "second run reports ok"
}

test_link_leaves_an_existing_relative_link_alone() {
    # The Fedora machine already has relative links from the old script. They
    # resolve to the right place, so they must be reported ok, not recreated.
    local box out
    box=$(sandbox)
    mkdir -p "$box/src" "$box/home"
    ln -s -- "../src" "$box/home/target"
    out=$(link "$box/src" "$box/home/target")
    assert_contains "$out" "ok" "relative link reported ok"
    assert_eq "$(readlink "$box/home/target")" "../src" "relative link untouched"
}

test_link_backs_up_a_real_directory_in_the_way() {
    local box
    box=$(sandbox)
    mkdir -p "$box/src" "$box/home/target"
    : > "$box/home/target/keepme"
    link "$box/src" "$box/home/target" >/dev/null
    if [ ! -L "$box/home/target" ]; then
        fail "target is not a symlink after backup"
    fi
    if ! ls -d "$box/home/target.backup-"* >/dev/null 2>&1; then
        fail "no backup directory created"
        return
    fi
    if [ ! -f "$(ls -d "$box/home/target.backup-"*)/keepme" ]; then
        fail "backup did not preserve contents"
    fi
}

test_link_replaces_a_symlink_pointing_somewhere_else() {
    local box
    box=$(sandbox)
    mkdir -p "$box/src" "$box/other" "$box/home"
    ln -s -- "$box/other" "$box/home/target"
    link "$box/src" "$box/home/target" >/dev/null
    assert_eq "$(resolve "$box/home/target")" "$(resolve "$box/src")" "repointed"
}

test_link_creates_missing_parent_directories() {
    local box
    box=$(sandbox)
    mkdir -p "$box/src"
    link "$box/src" "$box/home/deep/target" >/dev/null
    if [ ! -L "$box/home/deep/target" ]; then
        fail "parent directories not created"
    fi
}

test_link_reports_ok_for_an_existing_file_link() {
    # home/.zshrc and home/.zprofile are files, not directories. This is the
    # case a resolve() that does not dereference symlinks gets wrong, silently
    # backing up and relinking a correct link on every run.
    local box out
    box=$(sandbox)
    mkdir -p "$box/repo" "$box/home"
    : > "$box/repo/.zshrc"
    link "$box/repo/.zshrc" "$box/home/.zshrc" >/dev/null
    out=$(link "$box/repo/.zshrc" "$box/home/.zshrc")
    assert_contains "$out" "ok" "file link reported ok on second run"
    if ls -d "$box/home/.zshrc.backup-"* >/dev/null 2>&1; then
        fail "a correct file link was backed up and relinked"
    fi
}

run_test test_link_creates_an_absolute_symlink
run_test test_link_reports_ok_for_an_existing_correct_link
run_test test_link_leaves_an_existing_relative_link_alone
run_test test_link_backs_up_a_real_directory_in_the_way
run_test test_link_replaces_a_symlink_pointing_somewhere_else
run_test test_link_creates_missing_parent_directories
run_test test_link_reports_ok_for_an_existing_file_link
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/install_test.sh test_link`
Expected: FAIL with `link: command not found`.

- [ ] **Step 3: Implement `link()`**

In `install.sh`, insert after `tool()`:

```bash
# ---------------------------------------------------------------------------
# Linking
# ---------------------------------------------------------------------------

link() {
    # Point $2 at $1, backing up anything real already there.
    #
    # The target is absolute. The previous version computed a relative path
    # with `realpath --relative-to=`, which is GNU-only and fails on BSD.
    # Existing relative links resolve to the same place, so they are reported
    # ok and left untouched rather than churned.
    local src=$1 dest=$2

    if [ "${dry_run:-0}" = 1 ]; then
        if [ -L "$dest" ] && [ "$(resolve "$dest")" = "$(resolve "$src")" ]; then
            printf '  ok     %s\n' "$dest"
        else
            printf '  link   %s (dry run)\n' "$dest"
        fi
        return 0
    fi

    if [ -L "$dest" ] && [ "$(resolve "$dest")" = "$(resolve "$src")" ]; then
        printf '  ok     %s\n' "$dest"
        return 0
    fi

    if [ -e "$dest" ] || [ -L "$dest" ]; then
        mv -- "$dest" "$dest.backup-$stamp"
        printf '  backup %s.backup-%s\n' "$dest" "$stamp"
    fi

    mkdir -p -- "$(dirname -- "$dest")"
    ln -s -- "$(resolve "$src")" "$dest"
    printf '  link   %s\n' "$dest"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/install_test.sh`
Expected: `33 test(s), 0 failure(s), 1 skipped`.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install_test.sh
git commit -m "Make linking work on BSD userlands

realpath --relative-to= is GNU-only and was the reason install.sh could
not run on macOS at all. Symlink targets are now absolute, computed with
resolve().

Existing relative links on the Fedora machine resolve to the same paths,
so they report ok and are left in place. Nothing is recreated."
```

---

### Task 5: Package queries and installation

**Files:**
- Modify: `install.sh`
- Modify: `tests/install_test.sh`

- [ ] **Step 1: Write the failing tests**

In `tests/install_test.sh`, insert before the final `printf '\n%d test(s)` line:

```bash
# --------------------------------------------------------------------------
# Package installation
#
# dnf, rpm, brew and sudo are replaced with shims on PATH that log their
# arguments to a file, so these tests never touch the real system.
# --------------------------------------------------------------------------

make_shims() {
    # make_shims <dir> <brew-formulae> <brew-casks> <installed-rpms>
    # Creates dnf/rpm/brew/sudo shims in <dir>/bin, logging to <dir>/calls.log.
    local dir=$1 formulae=$2 casks=$3 rpms=$4
    mkdir -p "$dir/bin"
    : > "$dir/calls.log"

    cat > "$dir/bin/brew" <<SHIM
#!/bin/sh
printf 'brew %s\n' "\$*" >> "$dir/calls.log"
case "\$1 \$2" in
    "list --formula") printf '%s\n' $formulae ;;
    "list --cask")    printf '%s\n' $casks ;;
    *) [ -f "$dir/fail" ] && { printf 'brew: simulated failure\n' >&2; exit 1; } ;;
esac
exit 0
SHIM

    cat > "$dir/bin/rpm" <<SHIM
#!/bin/sh
printf 'rpm %s\n' "\$*" >> "$dir/calls.log"
for installed in $rpms; do
    [ "\$3" = "\$installed" ] && exit 0
done
exit 1
SHIM

    cat > "$dir/bin/dnf" <<SHIM
#!/bin/sh
printf 'dnf %s\n' "\$*" >> "$dir/calls.log"
[ -f "$dir/fail" ] && { printf 'dnf: simulated failure\n' >&2; exit 1; }
exit 0
SHIM

    cat > "$dir/bin/sudo" <<SHIM
#!/bin/sh
shift_args=\$*
printf 'sudo %s\n' "\$shift_args" >> "$dir/calls.log"
exec "\$@"
SHIM

    chmod +x "$dir/bin/brew" "$dir/bin/rpm" "$dir/bin/dnf" "$dir/bin/sudo"
}

test_missing_packages_filters_installed_rpms() {
    local box
    box=$(sandbox)
    make_shims "$box" "" "" "btop zsh"
    assert_eq "$(PATH="$box/bin:$PATH"; platform=fedora; missing_packages "btop zsh helix")" \
        "helix" "only helix missing"
}

test_missing_packages_returns_everything_when_none_installed() {
    local box
    box=$(sandbox)
    make_shims "$box" "" "" ""
    assert_eq "$(PATH="$box/bin:$PATH"; platform=fedora; missing_packages "btop helix")" \
        "btop helix" "both missing"
}

test_missing_packages_is_empty_when_all_installed() {
    local box
    box=$(sandbox)
    make_shims "$box" "" "" "btop helix"
    assert_eq "$(PATH="$box/bin:$PATH"; platform=fedora; missing_packages "btop helix")" \
        "" "nothing missing"
}

test_missing_brew_formulae_uses_the_cached_list() {
    local box out
    box=$(sandbox)
    make_shims "$box" "rbenv zsh" "" ""
    out=$(
        PATH="$box/bin:$PATH"
        platform=macos
        load_brew_cache
        missing_packages "rbenv helix"
    )
    assert_eq "$out" "helix" "helix missing, rbenv present"
}

test_load_brew_cache_queries_formulae_and_casks_once_each() {
    local box
    box=$(sandbox)
    make_shims "$box" "rbenv" "amethyst" ""
    (
        PATH="$box/bin:$PATH"
        platform=macos
        load_brew_cache
        missing_packages "rbenv zsh" >/dev/null
        missing_packages "rbenv helix" >/dev/null
    )
    assert_eq "$(grep -c 'brew list --formula' "$box/calls.log")" "1" "formulae queried once"
    assert_eq "$(grep -c 'brew list --cask' "$box/calls.log")" "1" "casks queried once"
}

test_install_packages_invokes_dnf_once_for_the_whole_set() {
    local box
    box=$(sandbox)
    make_shims "$box" "" "" ""
    (
        PATH="$box/bin:$PATH"
        platform=fedora
        dry_run=0
        install_packages "sway grim slurp"
    ) >/dev/null 2>&1
    assert_eq "$(grep -c '^dnf install' "$box/calls.log")" "1" "one dnf call"
    assert_contains "$(cat "$box/calls.log")" "sway grim slurp" "all packages in one call"
}

test_install_packages_does_nothing_when_the_set_is_empty() {
    local box
    box=$(sandbox)
    make_shims "$box" "" "" ""
    (
        PATH="$box/bin:$PATH"
        platform=fedora
        dry_run=0
        install_packages ""
    ) >/dev/null 2>&1
    assert_eq "$(wc -l < "$box/calls.log" | tr -d ' ')" "0" "no package manager invoked"
}

test_install_packages_reports_failure() {
    local box status
    box=$(sandbox)
    make_shims "$box" "" "" ""
    : > "$box/fail"
    (
        PATH="$box/bin:$PATH"
        platform=fedora
        dry_run=0
        install_packages "sway"
    ) >/dev/null 2>&1
    status=$?
    assert_fails $status "failure propagated"
}

test_install_packages_skips_the_manager_in_dry_run() {
    local box
    box=$(sandbox)
    make_shims "$box" "" "" ""
    (
        PATH="$box/bin:$PATH"
        platform=fedora
        dry_run=1
        install_packages "sway"
    ) >/dev/null 2>&1
    assert_eq "$(wc -l < "$box/calls.log" | tr -d ' ')" "0" "dry run invoked nothing"
}

run_test test_missing_packages_filters_installed_rpms
run_test test_missing_packages_returns_everything_when_none_installed
run_test test_missing_packages_is_empty_when_all_installed
run_test test_missing_brew_formulae_uses_the_cached_list
run_test test_load_brew_cache_queries_formulae_and_casks_once_each
run_test test_install_packages_invokes_dnf_once_for_the_whole_set
run_test test_install_packages_does_nothing_when_the_set_is_empty
run_test test_install_packages_reports_failure
run_test test_install_packages_skips_the_manager_in_dry_run
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/install_test.sh missing_packages`
Expected: FAIL with `missing_packages: command not found`.

- [ ] **Step 3: Implement the package functions**

In `install.sh`, insert after `link()`:

```bash
# ---------------------------------------------------------------------------
# Packages
#
# What is already installed is queried locally — rpm -q on Fedora, brew list on
# macOS. Neither needs privileges or the network, so a machine that is already
# configured runs the whole script without ever invoking a package manager.
# ---------------------------------------------------------------------------

brew_formulae=''
brew_casks=''
brew_cache_loaded=0

load_brew_cache() {
    # brew list is slow enough to be worth doing once. --formula and --cask are
    # separate queries: a plain `brew list` conflates them, so a cask-installed
    # font would never match a --cask declaration and would reinstall forever.
    if [ "$brew_cache_loaded" = 1 ]; then
        return 0
    fi
    brew_formulae=$(brew list --formula 2>/dev/null || true)
    brew_casks=$(brew list --cask 2>/dev/null || true)
    brew_cache_loaded=1
}

missing_packages() {
    # Print the subset of the space-separated list $1 that is not installed.
    local pkg missing=''
    for pkg in $1; do
        case "$platform" in
            fedora)
                if rpm -q --quiet "$pkg"; then
                    continue
                fi
                ;;
            macos)
                load_brew_cache
                if list_contains "$pkg" "$brew_formulae"; then
                    continue
                fi
                ;;
        esac
        missing="$missing $pkg"
    done
    # shellcheck disable=SC2086
    printf '%s\n' $missing
}

missing_casks() {
    local pkg missing=''
    load_brew_cache
    for pkg in $1; do
        if list_contains "$pkg" "$brew_casks"; then
            continue
        fi
        missing="$missing $pkg"
    done
    # shellcheck disable=SC2086
    printf '%s\n' $missing
}

install_packages() {
    # Install the space-separated list $1 in one transaction. Nothing to do for
    # an empty list, which is the common case on a configured machine.
    if [ -z "${1// /}" ]; then
        return 0
    fi

    if [ "${dry_run:-0}" = 1 ]; then
        printf '  would install %s\n' "$1"
        return 0
    fi

    case "$platform" in
        fedora)
            # shellcheck disable=SC2086
            sudo dnf install -y $1
            ;;
        macos)
            # shellcheck disable=SC2086
            brew install $1
            ;;
        *)
            printf 'no package manager for platform %s\n' "$platform" >&2
            return 1
            ;;
    esac
}

install_casks() {
    if [ -z "${1// /}" ]; then
        return 0
    fi
    if [ "${dry_run:-0}" = 1 ]; then
        printf '  would install cask %s\n' "$1"
        return 0
    fi
    # shellcheck disable=SC2086
    brew install --cask $1
}
```

Note: `${1// /}` is bash pattern substitution, available in bash 3.2. It collapses a whitespace-only string to empty so `install_packages "  "` is a no-op.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/install_test.sh`
Expected: `42 test(s), 0 failure(s), 1 skipped`.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install_test.sh
git commit -m "Install missing packages through the platform's manager

What is installed is queried with rpm -q or brew list, both local and
unprivileged, so a configured machine never invokes a package manager and
never asks for sudo. That keeps re-running the script the cheap check
AGENTS.md describes it as.

brew list --formula and --cask are queried separately. A plain brew list
conflates them, which would leave every cask permanently 'missing' and
reinstalling on every run."
```

---

### Task 6: Orchestration — `main()`, the unassigned warning, and the summary

**Files:**
- Modify: `install.sh`
- Modify: `tests/install_test.sh`

- [ ] **Step 1: Write the failing tests**

In `tests/install_test.sh`, insert before the final `printf '\n%d test(s)` line:

```bash
# --------------------------------------------------------------------------
# Orchestration
#
# These run install.sh as a subprocess against a fake repository and a fake
# $HOME, with the package managers shimmed.
# --------------------------------------------------------------------------

make_fake_repo() {
    # make_fake_repo <dir> — a miniature copy of this repository's layout.
    local dir=$1
    mkdir -p "$dir/config/alpha" "$dir/config/beta" "$dir/config/orphan" "$dir/home/.zsh"
    : > "$dir/config/alpha/conf"
    : > "$dir/config/beta/conf"
    : > "$dir/config/orphan/conf"
    : > "$dir/home/.zshrc"
    : > "$dir/home/.zsh/theme"
    cp "$repo_root/install.sh" "$dir/install.sh"
    chmod +x "$dir/install.sh"

    cat > "$dir/manifest.sh" <<'MANIFEST'
tool alpha --platforms "fedora macos" --config alpha --dnf "alpha" --brew "alpha"
tool beta  --platforms "fedora"       --config beta  --dnf "beta"
tool zsh   --platforms "fedora macos" --home ".zshrc .zsh" --dnf "zsh" --brew "zsh"
MANIFEST
}

run_install() {
    # run_install <repo> <home> <shims> <platform> [args...]
    local repo=$1 home=$2 shims=$3 plat=$4
    shift 4
    HOME="$home" PATH="$shims/bin:$PATH" DOTFILES_PLATFORM="$plat" \
        "$repo/install.sh" "$@" 2>&1
}

test_macos_links_only_its_tools() {
    local box repo home out
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "alpha zsh" "" ""
    out=$(run_install "$repo" "$home" "$box" macos)
    if [ ! -L "$home/.config/alpha" ]; then fail "alpha not linked: $out"; fi
    if [ -e "$home/.config/beta" ]; then fail "beta linked on macos: $out"; fi
    if [ ! -L "$home/.zshrc" ]; then fail ".zshrc not linked: $out"; fi
    if [ ! -L "$home/.zsh" ]; then fail ".zsh not linked: $out"; fi
}

test_fedora_links_its_extra_tools() {
    local box repo home out
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "" "" "alpha beta zsh"
    out=$(run_install "$repo" "$home" "$box" fedora)
    if [ ! -L "$home/.config/beta" ]; then fail "beta not linked on fedora: $out"; fi
}

test_unassigned_config_directory_is_reported() {
    local box repo home out
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "alpha zsh" "" ""
    out=$(run_install "$repo" "$home" "$box" macos)
    assert_contains "$out" "unassigned: orphan" "orphan reported"
    if [ -e "$home/.config/orphan" ]; then fail "orphan should not be linked"; fi
}

test_unassigned_home_entry_is_reported() {
    local box repo home out
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    : > "$repo/home/.undeclared"
    make_shims "$box" "alpha zsh" "" ""
    out=$(run_install "$repo" "$home" "$box" macos)
    assert_contains "$out" "unassigned: .undeclared" "undeclared home entry reported"
}

test_a_failing_tool_is_not_linked_and_the_run_continues() {
    local box repo home out status
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    # zsh is installed, alpha is not; brew install fails for everything.
    make_shims "$box" "zsh" "" ""
    : > "$box/fail"
    out=$(run_install "$repo" "$home" "$box" macos); status=$?
    if [ -e "$home/.config/alpha" ]; then fail "failed tool was linked: $out"; fi
    if [ ! -L "$home/.zshrc" ]; then fail "run did not continue past failure: $out"; fi
    assert_contains "$out" "alpha" "failure mentions the tool"
    assert_fails $status "exit status is non-zero"
}

test_an_already_linked_failing_tool_keeps_its_link() {
    local box repo home
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "alpha zsh" "" ""
    run_install "$repo" "$home" "$box" macos >/dev/null
    # Now make alpha look uninstalled and make installs fail.
    make_shims "$box" "zsh" "" ""
    : > "$box/fail"
    run_install "$repo" "$home" "$box" macos >/dev/null
    if [ ! -L "$home/.config/alpha" ]; then
        fail "an existing working link was torn down by a later failure"
    fi
}

test_a_configured_machine_invokes_no_package_manager() {
    local box repo home
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "alpha zsh" "" ""
    run_install "$repo" "$home" "$box" macos >/dev/null
    if grep -q '^brew install' "$box/calls.log"; then
        fail "brew install was invoked with nothing missing"
    fi
    if grep -q '^sudo' "$box/calls.log"; then
        fail "sudo was requested with nothing missing"
    fi
}

test_an_unknown_platform_is_a_hard_error() {
    local box repo home out status
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "" "" ""
    out=$(run_install "$repo" "$home" "$box" plan9); status=$?
    assert_fails $status "unknown platform exits non-zero"
    assert_contains "$out" "plan9" "names the platform"
    assert_contains "$out" "fedora" "names what is supported"
}

test_post_command_runs_after_install() {
    local box repo home
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    cat > "$repo/manifest.sh" <<MANIFEST
tool alpha --platforms "macos" --config alpha --brew "alpha" --post "touch $box/post-ran"
MANIFEST
    make_shims "$box" "alpha" "" ""
    run_install "$repo" "$home" "$box" macos >/dev/null
    if [ ! -f "$box/post-ran" ]; then fail "--post command did not run"; fi
}

run_test test_macos_links_only_its_tools
run_test test_fedora_links_its_extra_tools
run_test test_unassigned_config_directory_is_reported
run_test test_unassigned_home_entry_is_reported
run_test test_a_failing_tool_is_not_linked_and_the_run_continues
run_test test_an_already_linked_failing_tool_keeps_its_link
run_test test_a_configured_machine_invokes_no_package_manager
run_test test_an_unknown_platform_is_a_hard_error
run_test test_post_command_runs_after_install
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/install_test.sh test_macos_links`
Expected: FAIL — `main` still prints `not implemented yet` and links nothing.

- [ ] **Step 3: Implement the orchestration**

In `install.sh`, replace the placeholder `main()` with:

```bash
# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

platform=''
dry_run=0
failed_tools=''

require_package_manager() {
    case "$platform" in
        fedora)
            if ! command -v dnf >/dev/null 2>&1; then
                printf 'dnf not found. This does not look like a Fedora system.\n' >&2
                return 1
            fi
            ;;
        macos)
            if ! command -v brew >/dev/null 2>&1; then
                printf 'Homebrew not found. Install it first:\n' >&2
                printf '  https://brew.sh\n' >&2
                return 1
            fi
            ;;
        *)
            printf 'Unsupported platform: %s\n' "$platform" >&2
            printf 'Supported platforms: fedora, macos\n' >&2
            return 1
            ;;
    esac
}

tool_index_for_config() {
    # Print the manifest index declaring config directory $1, or nothing.
    local i=0
    while [ "$i" -lt "${#tool_names[@]}" ]; do
        if [ "${tool_config[$i]}" = "$1" ]; then
            printf '%s\n' "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

home_entry_is_declared() {
    local i=0
    while [ "$i" -lt "${#tool_names[@]}" ]; do
        if list_contains "$1" "${tool_home[$i]}"; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

report_unassigned() {
    # Anything in config/ or home/ that no manifest entry mentions. Adding
    # config/zellij/ later and forgetting to declare it should be loud.
    local dir entry name
    for dir in "$files_dir"/config/*/; do
        [ -d "$dir" ] || continue
        name=$(basename -- "${dir%/}")
        if ! tool_index_for_config "$name" >/dev/null; then
            printf '  unassigned: %s (declared by no tool, not linked)\n' "$name"
        fi
    done
    for entry in "$files_dir"/home/.*; do
        name=$(basename -- "$entry")
        case "$name" in . | ..) continue ;; esac
        [ -e "$entry" ] || continue
        if ! home_entry_is_declared "$name"; then
            printf '  unassigned: %s (declared by no tool, not linked)\n' "$name"
        fi
    done
}

process_tool() {
    # Install and link one manifest entry. Returns non-zero if it failed.
    local i=$1
    local name=${tool_names[$i]}
    local pkgs='' casks='' missing='' missing_cask='' entry

    case "$platform" in
        fedora) pkgs=${tool_dnf[$i]} ;;
        macos)  pkgs=${tool_brew[$i]}; casks=${tool_cask[$i]} ;;
    esac

    printf '%s\n' "$name"

    missing=$(missing_packages "$pkgs")
    if [ -n "${missing// /}" ]; then
        if ! install_packages "$missing"; then
            printf '  FAILED to install: %s\n' "$missing" >&2
            printf '  skipping links for %s\n' "$name" >&2
            return 1
        fi
    fi

    if [ -n "${casks// /}" ]; then
        missing_cask=$(missing_casks "$casks")
        if [ -n "${missing_cask// /}" ]; then
            if ! install_casks "$missing_cask"; then
                printf '  FAILED to install cask: %s\n' "$missing_cask" >&2
                printf '  skipping links for %s\n' "$name" >&2
                return 1
            fi
        fi
    fi

    if [ -n "${tool_post[$i]}" ]; then
        if [ "$dry_run" = 1 ]; then
            printf '  would run %s\n' "${tool_post[$i]}"
        elif ! eval "${tool_post[$i]}"; then
            printf '  FAILED post-install command: %s\n' "${tool_post[$i]}" >&2
            return 1
        fi
    fi

    if [ -n "${tool_config[$i]}" ]; then
        link "$files_dir/config/${tool_config[$i]}" \
             "$HOME/.config/${tool_config[$i]}"
    fi

    for entry in ${tool_home[$i]}; do
        link "$files_dir/home/$entry" "$HOME/$entry"
    done
}

usage() {
    cat <<'USAGE'
Usage: install.sh [--dry-run] [--help]

Detects the platform, installs the packages that platform's tools need, and
links this repository's configuration into ~/.config and $HOME.

  --dry-run   Print what would be installed and linked; change nothing.
  --help      Show this message.

What each platform receives is declared in manifest.sh.
USAGE
}

main() {
    while [ $# -gt 0 ]; do
        case $1 in
            --dry-run) dry_run=1; shift ;;
            --help|-h) usage; return 0 ;;
            *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; return 2 ;;
        esac
    done

    platform=$(detect_platform)
    require_package_manager || return 1

    printf 'Platform: %s\n' "$platform"
    if [ "$dry_run" = 1 ]; then
        printf 'Dry run: nothing will be installed or linked.\n'
    fi

    manifest_reset
    # shellcheck disable=SC1091
    . "$files_dir/manifest.sh"

    printf '\n'
    report_unassigned

    local i=0
    printf '\n'
    while [ "$i" -lt "${#tool_names[@]}" ]; do
        if list_contains "$platform" "${tool_platforms[$i]}"; then
            if ! process_tool "$i"; then
                failed_tools="$failed_tools ${tool_names[$i]}"
            fi
        fi
        i=$((i + 1))
    done

    printf '\n'
    if [ -n "${failed_tools// /}" ]; then
        printf 'Failed:%s\n' "$failed_tools"
        printf 'Their configuration was not linked. Fix the errors above and\n'
        printf 're-run; only what is still missing will be retried.\n'
        return 1
    fi

    printf 'Done.\n'
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/install_test.sh`
Expected: `51 test(s), 0 failure(s), 1 skipped`.

- [ ] **Step 5: Verify syntax**

Run: `bash -n install.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

- [ ] **Step 6: Commit**

```bash
git add install.sh tests/install_test.sh
git commit -m "Install and link per tool, continuing past failures

A tool whose packages will not install does not get its configuration
linked, and the run moves on to the next tool. The summary names what
failed and a re-run retries only what is still missing.

A tool that was linked by an earlier successful run keeps its link even
if a later run fails to install it. Tearing down a working symlink
because of a transient network error would be worse than the failure.

Anything in config/ or home/ that no manifest entry mentions is reported
as unassigned, so adding a directory and forgetting to declare it is
loud rather than silent."
```

---

### Task 7: `--dry-run` end to end

**Files:**
- Modify: `tests/install_test.sh`

The flag was implemented in Tasks 4-6. This task proves it changes nothing.

- [ ] **Step 1: Write the failing tests**

In `tests/install_test.sh`, insert before the final `printf '\n%d test(s)` line:

```bash
# --------------------------------------------------------------------------
# --dry-run
# --------------------------------------------------------------------------

test_dry_run_creates_no_links() {
    local box repo home out
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "" "" ""
    out=$(run_install "$repo" "$home" "$box" macos --dry-run)
    if [ -e "$home/.config/alpha" ]; then fail "dry run created a link: $out"; fi
    if [ -e "$home/.zshrc" ]; then fail "dry run created a home link: $out"; fi
}

test_dry_run_invokes_no_package_manager() {
    local box repo home
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "" "" ""
    run_install "$repo" "$home" "$box" macos --dry-run >/dev/null
    if grep -q '^brew install' "$box/calls.log"; then
        fail "dry run invoked brew install"
    fi
}

test_dry_run_reports_what_it_would_do() {
    local box repo home out
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "" "" ""
    out=$(run_install "$repo" "$home" "$box" macos --dry-run)
    assert_contains "$out" "would install alpha" "reports the install"
    assert_contains "$out" "dry run" "marks links as dry"
}

test_help_exits_zero_and_changes_nothing() {
    local box repo home out status
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "" "" ""
    out=$(run_install "$repo" "$home" "$box" macos --help); status=$?
    assert_ok $status "--help exits zero"
    assert_contains "$out" "Usage: install.sh" "prints usage"
    if [ -e "$home/.config/alpha" ]; then fail "--help linked something"; fi
}

test_an_unknown_flag_is_rejected() {
    local box repo home status
    box=$(sandbox); repo="$box/repo"; home="$box/home"
    make_fake_repo "$repo"; mkdir -p "$home"
    make_shims "$box" "" "" ""
    run_install "$repo" "$home" "$box" macos --nonsense >/dev/null; status=$?
    assert_fails $status "unknown flag rejected"
}

run_test test_dry_run_creates_no_links
run_test test_dry_run_invokes_no_package_manager
run_test test_dry_run_reports_what_it_would_do
run_test test_help_exits_zero_and_changes_nothing
run_test test_an_unknown_flag_is_rejected
```

- [ ] **Step 2: Run the tests**

Run: `tests/install_test.sh dry_run`
Expected: PASS. If any fail, fix `install.sh` — the behaviour is meant to exist already.

- [ ] **Step 3: Run the whole suite**

Run: `tests/install_test.sh`
Expected: `56 test(s), 0 failure(s), 1 skipped`.

- [ ] **Step 4: Commit**

```bash
git add tests/install_test.sh
git commit -m "Cover --dry-run and argument handling

The Fedora path cannot be exercised from the macOS machine this was
written on. --dry-run is how it gets validated there before a real run,
so it needs tests proving it genuinely changes nothing."
```

---

### Task 8: The real `manifest.sh`

**Files:**
- Create: `manifest.sh`

- [ ] **Step 1: Write the manifest**

Create `manifest.sh`:

```bash
# Which tools exist, where they run, and what they need.
#
# Sourced by install.sh, which defines tool(). This file contains nothing but
# tool lines. It is shell rather than JSON because the only worthwhile JSON
# parser is jq, which is itself a package this file would have to declare —
# install.sh would need to install its own parser before it could read what to
# install.
#
#   tool <name> --platforms "<ids>"  [--config <dir>]  [--home "<entries>"]
#               [--dnf "<pkgs>"] [--brew "<pkgs>"] [--cask "<casks>"]
#               [--post "<command>"]
#
# --config names a directory under config/, linked to ~/.config/<name>.
# --home names entries under home/, linked to $HOME.
# Packages are per manager: --dnf on Fedora, --brew and --cask on macOS.
#
# Platforms are distro-level, not family-level, because package names differ
# between distributions. Adding one means a new identifier here and a case in
# install.sh's require_package_manager and missing_packages.

# --- Everywhere -----------------------------------------------------------

tool zsh    --platforms "fedora macos" \
            --home ".zshrc .zprofile .zsh" \
            --dnf "zsh rbenv" --brew "zsh rbenv"

tool helix  --platforms "fedora macos" --config helix \
            --dnf "helix" --brew "helix"

tool btop   --platforms "fedora macos" --config btop \
            --dnf "btop" --brew "btop"

# --- Fedora only ----------------------------------------------------------
#
# The Wayland desktop. None of this runs on macOS: sway is a compositor,
# waybar is a Wayland bar, rofi-wayland a Wayland launcher, mako a Wayland
# notification daemon.
#
# kitty would run on macOS but is deliberately Fedora-only; the laptop uses a
# different terminal.

tool kitty  --platforms "fedora" --config kitty --dnf "kitty"

tool sway   --platforms "fedora" --config sway \
            --dnf "sway swaybg grim slurp wl-clipboard playerctl light"

tool waybar --platforms "fedora" --config waybar \
            --dnf "waybar jq gawk upower bluez"

tool rofi   --platforms "fedora" --config rofi --dnf "rofi-wayland"

tool mako   --platforms "fedora" --config mako --dnf "mako"

tool cava   --platforms "fedora" --config cava --dnf "cava"
```

- [ ] **Step 2: Verify it parses and produces the expected tools**

Run:

```bash
bash -n manifest.sh && DOTFILES_LIB_ONLY=1 bash -c '
  . ./install.sh
  . ./manifest.sh
  i=0
  while [ "$i" -lt "${#tool_names[@]}" ]; do
    printf "%-8s %s\n" "${tool_names[$i]}" "${tool_platforms[$i]}"
    i=$((i + 1))
  done'
```

Expected: nine lines — `zsh`, `helix`, `btop` on `fedora macos`; `kitty`, `sway`, `waybar`, `rofi`, `mako`, `cava` on `fedora`.

- [ ] **Step 3: Confirm nothing is unassigned**

Run: `./install.sh --dry-run`
Expected: `Platform: macos`, no `unassigned:` lines (every one of the eight `config/` directories is declared), and `would install helix btop` — `zsh` and `rbenv` are already present on this machine.

**If an `unassigned:` line appears, a `config/` directory is missing from the manifest.** Add it before continuing.

- [ ] **Step 4: Run the suite**

Run: `tests/install_test.sh`
Expected: `56 test(s), 0 failure(s), 1 skipped`. The tests use their own fake manifest, so the real one cannot affect them.

- [ ] **Step 5: Commit**

```bash
git add manifest.sh
git commit -m "Declare what each platform gets

Each tool is declared once, with the platforms it applies to and its
package names per manager, so a cross-platform tool is not written into
two places where the copies can drift.

Packages sit with the tool that needs them: grim and slurp are visibly
sway's dependencies, so a platform without sway gets neither.

Fedora package names are unverified — they cannot be checked from macOS.
Fonts are absent for the same reason; the Nerd Font packaging on Fedora
needs checking before it can be declared."
```

---

### Task 9: Shell configuration guards

**Files:**
- Modify: `home/.zshrc:8`, `home/.zshrc:17`, `home/.zshrc:19`
- Modify: `home/.zprofile:1-3`

- [ ] **Step 1: Check the current state of the shell on this machine**

Run: `timeout 20 zsh -i -c 'echo SHELL-OK' 2>&1 | tail -5`

Expected on macOS **before** the fix: an `rbenv` error, or a clean run if rbenv happens to be installed. Record what you see — Step 5 compares against it.

- [ ] **Step 2: Guard `.zprofile`**

Replace the entire contents of `home/.zprofile` with:

```bash
# Login shell setup, shared between machines.
#
# This file is one symlink reaching both the Fedora desktop and the MacBook,
# so anything platform-specific is a runtime check rather than a separate file.

# Homebrew is not on the default PATH on Apple silicon, and nothing else in
# this file can find brew-installed tools until this runs.
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Added by `rbenv init` on wo  3 jun 2026 19:52:12 CEST.
# Guarded: this errored on startup on any machine without rbenv.
if command -v rbenv >/dev/null 2>&1; then
    eval "$(rbenv init - --no-rehash zsh)"
fi
```

- [ ] **Step 3: Guard `.zshrc`**

In `home/.zshrc`, replace line 8:

```zsh
zstyle :compinstall filename '/home/malum/.zshrc'
```

with:

```zsh
zstyle :compinstall filename "$HOME/.zshrc"
```

Then replace lines 17-19:

```zsh
export XDG_CURRENT_DESKTOP=sway

eval "$(rbenv init - zsh)"
```

with:

```zsh
# sway only exists on the Linux desktop. Claiming it on macOS would be a false
# statement about the session, which XDG-aware tools do act on.
if [[ "$OSTYPE" == linux* ]]; then
    export XDG_CURRENT_DESKTOP=sway
fi

# Guarded: unconditional, this errors on startup on a machine without rbenv.
if command -v rbenv >/dev/null 2>&1; then
    eval "$(rbenv init - zsh)"
fi
```

- [ ] **Step 4: Check syntax**

Run: `zsh -n home/.zshrc && zsh -n home/.zprofile && echo ZSH-SYNTAX-OK`
Expected: `ZSH-SYNTAX-OK`

- [ ] **Step 5: Verify the interactive shell is clean**

Run: `timeout 20 zsh -i -c 'echo SHELL-OK' 2>&1 | tail -5`
Expected: `SHELL-OK` with no error output. Compare against Step 1.

- [ ] **Step 6: Verify the platform guard actually guards**

Run: `timeout 20 zsh -i -c 'echo "desktop=[$XDG_CURRENT_DESKTOP]"' 2>&1 | tail -1`
Expected on macOS: `desktop=[]` — the variable is unset, because `$OSTYPE` is `darwin24.0` and not `linux*`.

- [ ] **Step 7: Commit**

```bash
git add home/.zshrc home/.zprofile
git commit -m "Guard the shell configuration at runtime

.zshrc and .zprofile are single files symlinked onto both machines, so
platform differences have to be runtime checks; the manifest cannot help
here, because it runs at install time and these run at every shell start.

rbenv init was unconditional and errored on startup on any machine
without rbenv, the MacBook included. XDG_CURRENT_DESKTOP=sway was a
false statement about a macOS session. .zprofile now puts Homebrew on
PATH, without which a login shell on Apple silicon finds none of it.

zstyle's compinstall filename pointed at /home/malum/.zshrc, a path that
exists on neither machine."
```

---

### Task 10: Documentation

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Update the README Layout table**

In `README.md`, in the `## Layout` section, add a row after the `home/` row:

```markdown
| `manifest.sh` | — | Declares which tools each platform gets and what they need |
```

- [ ] **Step 2: Add a Platforms section to the README**

In `README.md`, insert immediately before `## Installing`:

```markdown
## Platforms

| | Fedora | macOS |
|---|---|---|
| zsh, helix, btop | yes | yes |
| kitty | yes | no |
| sway, waybar, rofi, mako, cava | yes | no |

The Wayland half of this configuration cannot run on macOS: sway is a
compositor, waybar a Wayland bar, rofi-wayland a Wayland launcher, mako a
Wayland notification daemon. kitty would run there but is deliberately
Fedora-only; the laptop uses a different terminal.

`manifest.sh` is the source of truth. `install.sh` detects the platform from
`uname` and `/etc/os-release`, and warns about any directory in `config/` that
no manifest entry claims.
```

- [ ] **Step 3: Rewrite the README Installing section**

Replace the `## Installing` section, up to but not including `### Requirements`, with:

```markdown
## Installing

    git clone git@github.com:MalumAtire832/DotFiles.git ~/.files
    ~/.files/install.sh

On macOS, install [Homebrew](https://brew.sh) first; `install.sh` will not
bootstrap it.

`install.sh --dry-run` prints what it would install and link without changing
anything.

The script is idempotent. It installs only packages that are genuinely missing
— checked with `rpm -q` or `brew list`, neither of which needs privileges or
the network — so re-running on a configured machine invokes no package manager
and asks for no sudo. A target that is already the right symlink is left alone;
anything real found in the way is moved to `<path>.backup-<timestamp>`.

If a tool's packages fail to install, its configuration is not linked, the
error is reported, and the run continues to the next tool. Re-running retries
only what is still missing.
```

- [ ] **Step 4: Rewrite the README Requirements section**

Replace the `### Requirements` section body with:

```markdown
### Requirements

`manifest.sh` lists what each tool needs, per platform, and `install.sh`
installs it. The table below is the reasoning behind those entries.

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

Fonts are **not** in `manifest.sh` yet — see [TODO](#todo).

The GPU modules read AMD `amdgpu` sysfs paths and pick the discrete card by
VRAM size. They will report nothing on non-AMD hardware.

Hardware specifics that will need editing on another machine: the output
names `DP-1`, `DP-2` and `HDMI-A-1`, and their resolutions and rotations, in
`config/sway/config`.
```

- [ ] **Step 5: Update the README Adding a tool section**

Replace the `## Adding a tool` section body with:

```markdown
Move its directory into `config/`, then add a line to `manifest.sh` naming the
platforms it belongs on and the packages it needs. Re-run `install.sh`.

The manifest line is required. A directory nothing declares is reported as
`unassigned` on every run and is not linked.
```

- [ ] **Step 6: Add the TODO entries**

In `README.md`, add to the `## TODO` list:

```markdown
- Add a `zellij` configuration. The MacBook uses helix and zellij as its dev
  setup, and zellij has no config here yet.
- Get fonts into `manifest.sh`. On macOS they are Homebrew casks
  (`font-jetbrains-mono-nerd-font`, `font-iosevka-nerd-font`, `font-roboto`,
  all verified present in core). The Fedora side is unresolved: the Nerd Font
  variants may need a COPR, which means adding a `--copr` field to the manifest
  DSL.
```

- [ ] **Step 7: Update the AGENTS.md Layout block**

In `AGENTS.md`, replace the Layout code block with:

```
config/        -> symlinked to ~/.config/<name>   (whole directories)
  btop cava helix kitty mako rofi sway waybar
home/          -> symlinked to ~/<name>
  .zshrc .zprofile .zsh/
docs/          palette.svg, referenced by README; superpowers/ specs and plans
manifest.sh    declares which tools each platform gets and what they need
install.sh     detects the platform, installs packages, creates the symlinks
tests/         install_test.sh — dependency-free, run it directly
```

- [ ] **Step 8: Add a platform section to AGENTS.md**

In `AGENTS.md`, insert a new section immediately after `## Layout`:

```markdown
## Two platforms

This configuration runs on a Fedora Wayland desktop and on an M2 MacBook. The
Mac gets zsh, helix and btop; everything Wayland is Fedora-only, as is kitty.

`manifest.sh` is the source of truth, and `install.sh` warns about any
directory in `config/` or entry in `home/` that no manifest entry claims.

Two constraints follow, and both are easy to violate without noticing:

- **`install.sh` must run on bash 3.2.** That is what Apple ships at
  `/bin/bash`. Indexed arrays are fine; `declare -A` is not. This is why the
  manifest is stored in parallel indexed arrays rather than a map.
- **No GNU-only tools.** `readlink -f` and `realpath --relative-to=` are absent
  or differ on BSD; the latter is what stopped the old script running on macOS
  at all. Use `resolve()` instead. The same applies to `sed -i`, `date -d` and
  `stat -c`.

`.zshrc` and `.zprofile` are single files reaching both machines, so a
platform difference there is a runtime check — `$OSTYPE`, or `command -v` —
not a manifest entry. The manifest runs at install time; those files run at
every shell start.
```

- [ ] **Step 9: Update the AGENTS.md verification table**

In `AGENTS.md`, in the `## Verifying changes` table, replace the symlink row and add two rows:

```markdown
| symlink integrity | `./install.sh` — reports `ok` for everything and, with nothing missing, invokes no package manager |
| `install.sh`, `manifest.sh` | `tests/install_test.sh` — no dependencies, runs in a sandbox, never touches the real `$HOME` |
| anything platform-specific | `./install.sh --dry-run`, and `DOTFILES_PLATFORM=fedora ./install.sh --dry-run` to see the other platform's plan |
```

- [ ] **Step 10: Update the AGENTS.md Adding a tool section**

Replace the `## Adding a tool` section body with:

```markdown
Move its directory into `config/`, add a `tool` line to `manifest.sh` naming
its platforms and packages, and run `./install.sh`.

This is a change from how the repository used to work. `install.sh` previously
linked every directory in `config/` unconditionally, so adding one needed no
other edit. It no longer does: a directory nothing declares is reported as
`unassigned` on every run and is not linked. The trade is deliberate — it is
what lets the Mac avoid being handed a compositor's configuration.
```

- [ ] **Step 11: Verify the docs match reality**

Run:

```bash
DOTFILES_LIB_ONLY=1 bash -c '
  . ./install.sh; . ./manifest.sh
  i=0
  while [ "$i" -lt "${#tool_names[@]}" ]; do
    printf "%s: %s\n" "${tool_names[$i]}" "${tool_platforms[$i]}"
    i=$((i + 1))
  done'
```

Expected: the output matches the Platforms table added in Step 2. If they disagree, the table is wrong.

- [ ] **Step 12: Commit**

```bash
git add README.md AGENTS.md
git commit -m "Document the two platforms

Adding a tool now requires a manifest line. AGENTS.md previously said
nothing else was needed, which was true of the old script and is not
true of this one; the contradiction is stated rather than left for a
reader to trip over.

Both bash 3.2 and the no-GNU-tools constraint are written down. Neither
is visible from reading the script, and violating either breaks macOS
silently on a machine the author is probably not sitting at."
```

---

### Task 11: Verification on real machines

**Files:** none — this is a verification task.

- [ ] **Step 1: Run the full suite**

Run: `tests/install_test.sh`
Expected: `56 test(s), 0 failure(s), 1 skipped`, exit 0.

- [ ] **Step 2: Syntax-check everything**

Run: `bash -n install.sh && bash -n manifest.sh && bash -n tests/install_test.sh && zsh -n home/.zshrc && zsh -n home/.zprofile && echo ALL-SYNTAX-OK`
Expected: `ALL-SYNTAX-OK`

- [ ] **Step 3: Lint, if shellcheck is available**

Run: `command -v shellcheck >/dev/null && shellcheck install.sh manifest.sh tests/install_test.sh || echo "shellcheck not installed, skipping"`
Expected: clean, or the skip message. `shellcheck` was not present on the development machine; install with `brew install shellcheck` if you want this.

- [ ] **Step 4: Dry-run both platforms**

Run:

```bash
./install.sh --dry-run
DOTFILES_PLATFORM=fedora ./install.sh --dry-run
```

Expected: the macOS run plans `zsh`, `helix`, `btop` only. The Fedora run plans all nine and reports `dnf not found` — **that is correct behaviour on a Mac**, and confirms `require_package_manager` works. To see the full Fedora plan, the second command must be run on the Fedora machine.

- [ ] **Step 5: Real run on the MacBook**

Run: `./install.sh`

Expected: `helix` and `btop` are installed via brew (they were absent on the development machine); `zsh` and `rbenv` are reported as present and no install is attempted for them; `~/.config/helix`, `~/.config/btop`, `~/.zshrc`, `~/.zprofile` and `~/.zsh` become symlinks into the repository; `sway`, `waybar`, `rofi`, `mako`, `cava` and `kitty` never appear.

- [ ] **Step 6: Confirm the links**

Run: `ls -la ~/.config/ | grep -E 'helix|btop|sway|waybar|rofi|mako|cava|kitty'; ls -la ~/.zshrc ~/.zprofile ~/.zsh`

Expected: `helix` and `btop` are symlinks into `~/.files/config/`. None of the Wayland directories exist. The three home entries are symlinks.

- [ ] **Step 7: Confirm the second run is cheap**

Run: `time ./install.sh`

Expected: every line reports `ok`, no package manager runs, no sudo prompt, and it finishes in well under a second.

- [ ] **Step 8: Confirm the shell is clean**

Run: `timeout 20 zsh -i -c 'echo SHELL-OK; echo "desktop=[$XDG_CURRENT_DESKTOP]"' 2>&1 | tail -3`
Expected: `SHELL-OK` and `desktop=[]`, with no errors.

- [ ] **Step 9: Verify the Fedora package names — on the Fedora machine**

This cannot be done from macOS. On the Fedora desktop, run:

```bash
for p in sway swaybg grim slurp wl-clipboard playerctl light \
         waybar jq gawk upower bluez rofi-wayland mako cava kitty \
         btop helix zsh rbenv; do
    if dnf list --quiet "$p" >/dev/null 2>&1; then
        printf 'ok      %s\n' "$p"
    else
        printf 'MISSING %s\n' "$p"
    fi
done
```

Expected: every name reports `ok`. **Any `MISSING` line is a wrong package name in `manifest.sh`.** Find the right one with `dnf provides '*/bin/<command>'` and correct the manifest before running the installer for real there.

- [ ] **Step 10: Dry-run on Fedora before a real run**

On the Fedora machine: `./install.sh --dry-run`

Expected: all nine tools planned, and — because that machine is already fully set up — no `would install` lines at all. Any `would install` output means either a genuinely missing package or a wrong name that Step 9 did not catch.

- [ ] **Step 11: Real run on Fedora**

On the Fedora machine: `./install.sh`

Expected: every link reports `ok`. The existing relative symlinks resolve to the same paths, so nothing is recreated and no backup files appear.

Run `ls ~/.config/*.backup-* 2>/dev/null || echo "no backups created"` to confirm.

- [ ] **Step 12: Commit any manifest corrections**

If Step 9 found wrong package names:

```bash
git add manifest.sh
git commit -m "Correct Fedora package names

Verified against dnf on the Fedora machine. These could not be checked
from macOS, where the rest of this was written."
```

---

## Self-review notes

**Spec coverage.** Platform detection → Task 2. Portable linking → Tasks 1 and 4. Manifest DSL → Tasks 3 and 8. Execution flow including per-tool failure isolation, already-linked preservation and the unassigned warning → Task 6. Package queries and the no-op-when-nothing-missing property → Task 5. `--dry-run` → Tasks 6 and 7. Shell guards → Task 9. Documentation → Task 10. Verification → Task 11.

**Deviations from the spec, both flagged above:** `--tap` dropped as dead code (Homebrew merged cask-fonts into core), `--copr` deferred until the Fedora font entry needs it.

**Naming consistency.** `resolve`, `detect_platform`, `list_contains`, `manifest_reset`, `tool`, `link`, `load_brew_cache`, `missing_packages`, `missing_casks`, `install_packages`, `install_casks`, `require_package_manager`, `tool_index_for_config`, `home_entry_is_declared`, `report_unassigned`, `process_tool`, `usage`, `main`. Globals: `files_dir`, `stamp`, `platform`, `dry_run`, `failed_tools`, `brew_formulae`, `brew_casks`, `brew_cache_loaded`, and the eight `tool_*` arrays. Every name used in a later task is defined in an earlier one.
