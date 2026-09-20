#!/bin/bash
# Start waybar, replacing any running instance.
# Called from sway's exec_always, so it must be safe to run repeatedly.

SDIR="$HOME/.config/waybar"

# Wait for the old instance to actually exit and release its layer-surface
# before starting a new one; otherwise the two race and the bar can fail
# to map. -w blocks until the signalled processes are gone.
if pgrep -x waybar >/dev/null; then
  killall -w waybar 2>/dev/null
fi

# The cava helper is spawned by waybar, but a stale one can outlive it.
pkill -f "cava -p /tmp/waybar-cava.conf" 2>/dev/null

waybar -c "$SDIR/config.jsonc" -s "$SDIR/style.css" &
