#!/bin/bash
# Connected wireless peripherals and their battery, as waybar JSON.
#   usage: wireless-devices.sh <index>
# Prints the Nth device (0-based, ordered by serial for stable slots).
# Empty output when there is no device at that index, which hides the module.
#
# Covers both transports on purpose: the headset is on bluez, but the
# MX Master is on a Logitech HID++ receiver and never appears in
# `bluetoothctl devices Connected`.
#
# Two upower quirks handled here:
#   - HID++ devices report `percentage: N% (should be ignored)` and a coarse
#     `battery-level:` word instead; we show the word.
#   - upower reports the MX Master's type as `keyboard`, so the model string
#     wins over the type when deciding the icon.

idx="${1:-0}"

ICON_MOUSE=$(printf '')
ICON_KBD=$(printf '')
ICON_HEADSET=$(printf '')
ICON_GENERIC=$(printf '')

entries=()
while read -r dev; do
  [ -n "$dev" ] || continue
  case "$dev" in
    *DisplayDevice*|*line_power*) continue ;;
  esac

  info=$(upower -i "$dev" 2>/dev/null) || continue
  model=$(echo "$info"  | awk -F': *' '/^ *model:/   {print $2; exit}')
  serial=$(echo "$info" | awk -F': *' '/^ *serial:/  {print $2; exit}')
  [ -n "$model" ] || continue

  pct=$(echo "$info" | awk '/percentage:/ {gsub("%","",$2); print int($2); exit}')
  level=$(echo "$info" | awk '/battery-level:/ {print $2; exit}')
  ignore_pct=false
  echo "$info" | grep -q "should be ignored" && ignore_pct=true

  # icon: model keywords first (upower's type is unreliable), then type line
  lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *mouse*)                      icon="$ICON_MOUSE" ;;
    *keyboard*|*keychron*)        icon="$ICON_KBD" ;;
    *headset*|*headphone*|*wh-*)  icon="$ICON_HEADSET" ;;
    *)
      type=$(echo "$info" | grep -oE '^ +(mouse|keyboard|headset|headphones|speakers|phone|tablet)$' | head -1 | tr -d ' ')
      case "$type" in
        mouse)               icon="$ICON_MOUSE" ;;
        keyboard)            icon="$ICON_KBD" ;;
        headset|headphones)  icon="$ICON_HEADSET" ;;
        *)                   icon="$ICON_GENERIC" ;;
      esac
      ;;
  esac

  # value + alarm class
  cls=""
  if [ "$ignore_pct" = true ] && [ -n "$level" ] && [ "$level" != "unknown" ]; then
    value="$level"
    case "$level" in
      low)      cls="warning" ;;
      critical) cls="critical" ;;
    esac
    tip="$model — battery $level"
  elif [ -n "$pct" ]; then
    value="${pct}%"
    [ "$pct" -lt 20 ] && cls="warning"
    [ "$pct" -lt 10 ] && cls="critical"
    tip="$model — ${pct}%"
  else
    value="?"
    tip="$model — battery unknown"
  fi

  entries+=("${serial}|${icon}|${value}|${cls}|${tip}")
done < <(upower -e 2>/dev/null)

# stable ordering so a device keeps its slot between refreshes
IFS=$'\n' entries=($(printf '%s\n' "${entries[@]}" | sort))
unset IFS

[ "$idx" -lt "${#entries[@]}" ] || exit 0

IFS='|' read -r _serial icon value cls tip <<< "${entries[$idx]}"
printf '{"text":"%s  %s","tooltip":"%s","class":"%s"}\n' "$icon" "$value" "$tip" "$cls"
