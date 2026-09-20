#!/usr/bin/env bash
# App launcher — oxocarbon. Palette lives in colors.rasi.
dir="$HOME/.config/rofi"
theme="launcher_theme"

rofi -no-lazy-grab -show drun -modi drun -theme "$dir/$theme"
