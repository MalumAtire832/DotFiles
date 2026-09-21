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
    # A nonexistent leaf is fine as long as its parent directory exists.
    if [ -d "$1" ]; then
        (cd -- "$1" && pwd -P)
    else
        printf '%s/%s\n' \
            "$(cd -- "$(dirname -- "$1")" && pwd -P)" \
            "$(basename -- "$1")"
    fi
}

main() {
    printf 'not implemented yet\n'
}

if [ "${DOTFILES_LIB_ONLY:-0}" != 1 ]; then
    main "$@"
fi
