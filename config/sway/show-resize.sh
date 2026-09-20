#!/bin/bash
while true; do
  SIZE=$(swaymsg -t get_tree | jq -r '.. | select(.focused? == true) | "\(.rect.width)x\(.rect.height)"' 2>/dev/null | head -1)
  notify-send -t 90 -h string:x-canonical-private-synchronous:resize "  $SIZE"
  sleep 0.1
done
