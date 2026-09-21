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

# ---------------------------------------------------------------------------
# The manifest
#
# manifest.sh is sourced and contains nothing but `tool` lines. tool() records
# its arguments into parallel indexed arrays — one array per field, sharing an
# index — because bash 3.2 has no associative arrays and this script has to run
# on Apple's /bin/bash.
# ---------------------------------------------------------------------------

# Read these by index, never as "${tool_names[@]}". In bash 3.2 — which is
# what this has to run on — expanding an empty array that way under `set -u`
# is an unbound-variable error that kills the script. `${#tool_names[@]}` is
# safe, so an index loop bounded by it is the idiom to use.
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

list_contains() (
    # True when the whole word $1 appears in the space-separated list $2.
    #
    # The body is a subshell — ( ) rather than { } — so `set -f` is local to
    # it. Splitting $2 requires leaving it unquoted, and an unquoted expansion
    # does pathname expansion as well as word splitting: a list containing *
    # or ? would otherwise expand against whatever directory the caller
    # happens to be in, so the same inputs would give different answers
    # depending on where the script was run from.
    #
    # The comparison side is already safe: [ ] with both operands quoted is a
    # literal string comparison, never a pattern match.
    set -f
    needle=$1
    for word in $2; do
        if [ "$word" = "$needle" ]; then
            exit 0
        fi
    done
    exit 1
)

tool() {
    # tool <name> --platforms "<ids>" [--config <dir>] [--home "<entries>"]
    #             [--dnf "<pkgs>"] [--brew "<pkgs>"] [--cask "<casks>"]
    #             [--post "<command>"]
    #
    # Unknown flags are an error rather than being ignored, so a typo in the
    # manifest surfaces immediately instead of silently dropping a dependency.
    # For the same reason a value that is itself flag-shaped is rejected: in
    # `tool x --platforms --config sway` the author forgot the platforms
    # value, and taking "--config" as that value would give the tool a
    # platform matching nothing, so it would install nowhere and say nothing.
    #
    # A repeated flag takes the last value, as command lines usually do. A
    # repeated tool name is an error: later tasks iterate these arrays to
    # install and link, so a copy-pasted duplicate would do both twice.
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
                case $2 in
                    --*)
                        printf 'manifest: %s is missing its value (tool %s), got %s\n' \
                            "$1" "$name" "$2" >&2
                        return 1
                        ;;
                esac
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

    local i=0
    while [ "$i" -lt "${#tool_names[@]}" ]; do
        if [ "${tool_names[$i]}" = "$name" ]; then
            printf 'manifest: %s is declared twice\n' "$name" >&2
            return 1
        fi
        i=$((i + 1))
    done

    tool_names+=("$name")
    tool_platforms+=("$platforms")
    tool_config+=("$config")
    tool_home+=("$home")
    tool_dnf+=("$dnf")
    tool_brew+=("$brew")
    tool_cask+=("$cask")
    tool_post+=("$post")
}

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
    #
    # $1 is split with `read -a` rather than an unquoted `for pkg in $1`: the
    # latter performs pathname expansion as well as word splitting, so a
    # package name containing * or ? would expand against files in the
    # caller's working directory (the same hazard list_contains had before it
    # was made glob-safe). `read -a` only field-splits, never globs, and the
    # result is built without a leading separator so a single quoted printf
    # emits it as one line — `printf '%s\n' $missing` unquoted would instead
    # cycle its format once per word, printing each on its own line.
    local pkg missing='' pkgs
    read -r -a pkgs <<< "$1"
    for pkg in "${pkgs[@]}"; do
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
        if [ -z "$missing" ]; then
            missing=$pkg
        else
            missing="$missing $pkg"
        fi
    done
    printf '%s\n' "$missing"
}

missing_casks() {
    local pkg missing='' pkgs
    load_brew_cache
    read -r -a pkgs <<< "$1"
    for pkg in "${pkgs[@]}"; do
        if list_contains "$pkg" "$brew_casks"; then
            continue
        fi
        if [ -z "$missing" ]; then
            missing=$pkg
        else
            missing="$missing $pkg"
        fi
    done
    printf '%s\n' "$missing"
}

install_packages() {
    # Install the space-separated list $1 in one transaction. Nothing to do for
    # an empty list, which is the common case on a configured machine.
    #
    # $1 is split into an array with `read -a` and passed as "${pkgs[@]}"
    # rather than word-split with a bare unquoted $1: the latter also performs
    # pathname expansion, so a package name containing * or ? would expand
    # against files in the caller's working directory before ever reaching
    # dnf/brew.
    local pkgs
    if [ -z "${1// /}" ]; then
        return 0
    fi

    if [ "${dry_run:-0}" = 1 ]; then
        printf '  would install %s\n' "$1"
        return 0
    fi

    read -r -a pkgs <<< "$1"
    case "$platform" in
        fedora)
            sudo dnf install -y "${pkgs[@]}"
            ;;
        macos)
            brew install "${pkgs[@]}"
            ;;
        *)
            printf 'no package manager for platform %s\n' "$platform" >&2
            return 1
            ;;
    esac
}

install_casks() {
    local pkgs
    if [ -z "${1// /}" ]; then
        return 0
    fi
    if [ "${dry_run:-0}" = 1 ]; then
        printf '  would install cask %s\n' "$1"
        return 0
    fi
    read -r -a pkgs <<< "$1"
    brew install --cask "${pkgs[@]}"
}

main() {
    printf 'not implemented yet\n'
}

if [ "${DOTFILES_LIB_ONLY:-0}" != 1 ]; then
    main "$@"
fi
