#!/bin/bash
# Reports one amdgpu metric for waybar, as JSON.
# Usage: gpu.sh busy | vram | temp
# Picks the discrete card automatically: the one with the most VRAM.

pick_card() {
  local best="" best_total=0 dev total
  for dev in /sys/class/drm/card*/device; do
    [ -f "$dev/mem_info_vram_total" ] || continue
    total=$(cat "$dev/mem_info_vram_total" 2>/dev/null) || continue
    if [ "$total" -gt "$best_total" ]; then
      best_total=$total
      best=$dev
    fi
  done
  echo "$best"
}

CARD=$(pick_card)
if [ -z "$CARD" ]; then
  echo '{"text":"--","tooltip":"no amdgpu card found","class":"disconnected"}'
  exit 0
fi

hwmon_temp() {
  # $1 = label to match (edge/junction/mem); echoes millidegrees
  local h t
  for h in "$CARD"/hwmon/hwmon*; do
    for t in "$h"/temp*_label; do
      [ -f "$t" ] || continue
      if [ "$(cat "$t")" = "$1" ]; then
        cat "${t%_label}_input"
        return 0
      fi
    done
  done
  return 1
}

json() { # $1=text $2=tooltip $3=class
  printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$1" "$2" "$3"
}

case "$1" in
  busy)
    busy=$(cat "$CARD/gpu_busy_percent" 2>/dev/null || echo 0)
    fan=$(cat "$CARD"/hwmon/hwmon*/fan1_input 2>/dev/null | head -1)
    pwr=$(cat "$CARD"/hwmon/hwmon*/power1_average 2>/dev/null | head -1)
    tip="GPU load ${busy}%"
    [ -n "$fan" ] && tip="$tip\\nFan ${fan} RPM"
    [ -n "$pwr" ] && tip="$tip\\nPower $((pwr / 1000000)) W"
    cls=""
    [ "$busy" -gt 85 ] && cls="warning"
    [ "$busy" -gt 95 ] && cls="critical"
    json "${busy}%" "$tip" "$cls"
    ;;
  vram)
    used=$(cat "$CARD/mem_info_vram_used" 2>/dev/null || echo 0)
    total=$(cat "$CARD/mem_info_vram_total" 2>/dev/null || echo 1)
    used_g=$(awk -v u="$used" 'BEGIN{printf "%.1f", u/1073741824}')
    total_g=$(awk -v t="$total" 'BEGIN{printf "%.1f", t/1073741824}')
    pct=$(awk -v u="$used" -v t="$total" 'BEGIN{printf "%d", (u/t)*100}')
    cls=""
    [ "$pct" -gt 85 ] && cls="warning"
    [ "$pct" -gt 95 ] && cls="critical"
    json "${used_g}G" "VRAM ${used_g}G / ${total_g}G (${pct}%)" "$cls"
    ;;
  temp)
    raw=$(hwmon_temp junction) || raw=$(hwmon_temp edge) || raw=0
    c=$((raw / 1000))
    edge=$(hwmon_temp edge 2>/dev/null); edge=$((${edge:-0} / 1000))
    mem=$(hwmon_temp mem 2>/dev/null);  mem=$((${mem:-0} / 1000))
    cls=""
    [ "$c" -gt 75 ] && cls="warning"
    [ "$c" -gt 85 ] && cls="critical"
    json "${c}°C" "Junction ${c}°C\\nEdge ${edge}°C\\nMemory ${mem}°C" "$cls"
    ;;
  *)
    echo '{"text":"?","tooltip":"usage: gpu.sh busy|vram|temp"}'
    ;;
esac
