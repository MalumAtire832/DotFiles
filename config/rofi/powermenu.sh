#!/usr/bin/env bash
# Power menu — oxocarbon. Palette lives in colors.rasi.
dir="$HOME/.config/rofi"

rofi -show p -modi "p:$dir/off.sh" -theme "$dir/powermenu_theme.rasi"
