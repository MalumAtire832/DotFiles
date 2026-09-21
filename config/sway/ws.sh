#!/bin/sh
# Per-monitor workspace helper.
#
# Workspaces are namespaced <output-prefix><1-9>, so each monitor owns its own
# set of nine: left 11-19, center 21-29, right 31-39. This resolves the prefix
# from whichever output currently has focus, making Super+N relative to the
# monitor you are on.
#
# usage: ws.sh switch|move <1-9>

set -eu

action=${1:-}
num=${2:-}

case "$action" in
    switch|move) ;;
    *) echo "usage: ${0##*/} switch|move <1-9>" >&2; exit 2 ;;
esac

case "$num" in
    [1-9]) ;;
    *) echo "usage: ${0##*/} switch|move <1-9>" >&2; exit 2 ;;
esac

out=$(swaymsg -t get_outputs --raw | jq -r '.[] | select(.focused) | .name')

# Keep in sync with $monitor_left / $monitor_center / $monitor_right in sway/config.
case "$out" in
    DP-2)     prefix=1 ;;  # left
    HDMI-A-1) prefix=2 ;;  # center
    DP-1)     prefix=3 ;;  # right
    *)        prefix=2 ;;  # unknown output: fall back to the center set
esac

case "$action" in
    switch) swaymsg workspace number "$prefix$num" ;;
    move)   swaymsg move container to workspace number "$prefix$num" ;;
esac
