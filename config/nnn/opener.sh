#!/bin/sh
#
# nnn's file opener.
#
# Usage: nnn invokes this as `opener <file>`; point NNN_OPENER at it.
#
# Inside zellij, each text file nnn opens gets its own helix process rather
# than a buffer in a shared one: independent undo history, and closing one
# file doesn't touch any other. Those panes are merged into a single zellij
# stack next to the file tree, so switching between open files is zellij's
# own stack UI rather than helix's bufferline. Anything that is not text,
# and everything at all outside zellij, goes to xdg-open, so nnn behaves
# normally elsewhere.
#
# Panes are found by asking zellij which panes are *running* helix, not by
# a name or a remembered pane id, so an hx started from a zellij layout or
# by hand is adopted exactly like one the opener started itself. A file
# already open in one of them is matched by comparing that pane's running
# command against `hx <path>` -- exact, since hx is started with the path as
# its only argument -- and focused instead of reopened, so re-selecting a
# file in nnn can't spawn a second editor on it.

set -eu

file=$1

# No zellij session means no pane to send anything to.
[ -n "${ZELLIJ-}" ] || exec xdg-open "$file"

# Only text belongs in an editor. `file` reports the real type, so an
# extensionless script still lands in helix and a mislabelled .txt image
# still lands in an image viewer.
mime=$(file --mime-type -bL -- "$file" 2>/dev/null || echo application/octet-stream)
case $mime in
    text/* | inode/x-empty) ;;
    application/json | application/xml | application/javascript) ;;
    application/x-shellscript | application/toml | application/yaml) ;;
    *) exec xdg-open "$file" ;;
esac

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
    panes=$(zellij action list-panes --command --state --geometry --json 2>/dev/null) || panes='[]'
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
    zellij action focus-pane-id "terminal_$match"
    exit 0
fi

# Not open anywhere. Give it its own helix process, named for the stack's
# switcher list; --close-on-exit means `:q` cleans up its pane without
# touching any other.
new=$(zellij run --close-on-exit --name "$(basename -- "$path")" \
    --cwd "$(dirname -- "$path")" -- hx "$path")

if [ -n "$ids" ]; then
    # Other files are already open -- fold the new pane into their stack
    # rather than leaving it wherever zellij happened to place it. $ids is a
    # jq-produced list of bare integers, so the word-splitting here is safe
    # and deliberate.
    zellij action stack-panes -- $ids "$new"
fi

zellij action focus-pane-id "$new"
