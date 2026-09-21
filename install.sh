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
