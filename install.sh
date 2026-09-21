#!/usr/bin/env bash
#
# Link this repository's configuration into place.
#
# Idempotent: a target that is already the correct symlink is left alone, and
# anything real found at a target path is moved to <path>.backup-<timestamp>
# rather than overwritten. Safe to re-run after adding a directory.

set -euo pipefail

files_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
stamp=$(date +%Y%m%d-%H%M%S)

link() {
    local src=$1 dest=$2

    if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
        printf '  ok     %s\n' "$dest"
        return
    fi

    if [ -e "$dest" ] || [ -L "$dest" ]; then
        mv -- "$dest" "$dest.backup-$stamp"
        printf '  backup %s.backup-%s\n' "$dest" "$stamp"
    fi

    mkdir -p -- "$(dirname "$dest")"
    ln -s -- "$(realpath --relative-to="$(dirname "$dest")" "$src")" "$dest"
    printf '  link   %s\n' "$dest"
}

printf 'Linking into ~/.config\n'
for dir in "$files_dir"/config/*/; do
    link "${dir%/}" "$HOME/.config/$(basename "$dir")"
done

printf 'Linking into $HOME\n'
for entry in "$files_dir"/home/.*; do
    name=$(basename "$entry")
    case "$name" in . | ..) continue ;; esac
    link "$entry" "$HOME/$name"
done

printf 'Done.\n'
