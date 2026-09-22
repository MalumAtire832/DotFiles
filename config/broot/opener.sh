#!/bin/sh
#
# broot's file opener, invoked by the "edit" verb in verbs.hjson.
#
# Usage: broot invokes this as `opener.sh <file>` for text files only --
# verbs.hjson restricts the verb to apply_to: text_file, so anything else
# already fell through to broot's own default (xdg-open) before this runs.
#
# Inside zellij, each text file broot opens gets its own helix process
# rather than a buffer in a shared one: independent undo history, and
# closing one file doesn't touch any other. Those panes are merged into a
# single zellij stack next to the file tree, so switching between open
# files is zellij's own stack UI rather than helix's bufferline.
#
# Panes are found by asking zellij which panes are *running* helix, not by
# a name or a remembered pane id, so an hx started from a zellij layout or
# by hand is adopted exactly like one the opener started itself. A file
# already open in one of them is matched by comparing that pane's running
# command against `hx <path>` -- exact, since hx is started with the path as
# its only argument -- and focused instead of reopened, so re-selecting a
# file in broot can't spawn a second editor on it.

set -eu

file=$1

# No zellij session means no pane to send anything to.
[ -n "${ZELLIJ-}" ] || exec xdg-open "$file"

# zellij is installed to ~/.local/bin, which only ends up on PATH via
# .zshrc. A pane zellij itself spawns (this one, broot's pane) starts with
# a bare default PATH rather than inheriting the interactive shell's, so
# calling back into `zellij` by bare name fails here even though it's how
# this script got started.
zellij=$(command -v zellij || echo "$HOME/.local/bin/zellij")

path=$(realpath -- "$file")

# Every live helix pane, and among them one already editing this file. The
# table form of list-panes cannot be parsed safely -- both the title and the
# command contain spaces -- so this needs the JSON and therefore jq. Without
# jq both come back empty: the match always misses, so a reopened file gets
# a second pane instead of being focused, and there are no ids to stack the
# new pane with, so every file gets its own unstacked pane -- wrong, but not
# destructive.
match='' ids=''
if command -v jq >/dev/null 2>&1; then
    panes=$("$zellij" action list-panes --command --state --geometry --json 2>/dev/null) || panes='[]'
    match=$(printf '%s' "$panes" | jq -r --arg path "$path" '
        [ .[]
          | select(.is_plugin == false and .exited == false)
          | select((.pane_command // "") | test("^hx($|\\s)"))
        ]
        | map(select(.pane_command == "hx " + $path))
        | first.id // empty' 2>/dev/null) || match=''
    ids=$(printf '%s' "$panes" | jq -r '
        [ .[]
          | select(.is_plugin == false and .exited == false)
          | select((.pane_command // "") | test("^hx($|\\s)"))
        ]
        | map(.id)
        | join(" ")' 2>/dev/null) || ids=''
fi

if [ -n "$match" ]; then
    "$zellij" action focus-pane-id "terminal_$match"
    exit 0
fi

# Not open anywhere. Give it its own helix process, named for the stack's
# switcher list; --close-on-exit means `:q` cleans up its pane without
# touching any other.
new=$("$zellij" run --close-on-exit --name "$(basename -- "$path")" \
    --cwd "$(dirname -- "$path")" -- hx "$path")

if [ -n "$ids" ]; then
    # Other files are already open -- fold the new pane into their stack
    # rather than leaving it wherever zellij happened to place it. $ids is a
    # jq-produced list of bare integers, so the word-splitting here is safe
    # and deliberate.
    "$zellij" action stack-panes -- $ids "$new"
fi

"$zellij" action focus-pane-id "$new"
