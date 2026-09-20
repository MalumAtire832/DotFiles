#!/bin/bash
# Audio visualiser for waybar: cava bars coloured by amplitude,
# emitted as pango markup. Oxocarbon cool-to-hot ramp.
#
# NOTE: the digit -> markup mapping MUST be done in a single pass.
# Chained `sed s///g` rules re-read their own output, and the hex in an
# inserted colour code contains digits that later rules then replace,
# producing nested spans and invalid markup.

BARS=36
CONFIG=/tmp/waybar-cava.conf
PIPE=/tmp/waybar-cava.fifo

pkill -f "cava -p $CONFIG" 2>/dev/null
[ -p "$PIPE" ] && unlink "$PIPE"
mkfifo "$PIPE"

cat > "$CONFIG" <<CFG
[general]
bars = $BARS
framerate = 30
[output]
method = raw
raw_target = $PIPE
data_format = ascii
ascii_max_range = 7
CFG

cava -p "$CONFIG" &
CAVA_PID=$!
trap 'kill $CAVA_PID 2>/dev/null; unlink "$PIPE" 2>/dev/null' EXIT

awk '
BEGIN {
  g[0]="▁"; c[0]="#08bdba"
  g[1]="▂"; c[1]="#3ddbd9"
  g[2]="▃"; c[2]="#33b1ff"
  g[3]="▄"; c[3]="#82cfff"
  g[4]="▅"; c[4]="#be95ff"
  g[5]="▆"; c[5]="#ff7eb6"
  g[6]="▇"; c[6]="#ee5396"
  g[7]="█"; c[7]="#f1c21b"
}
{
  gsub(/;/, "")
  out = ""
  n = length($0)
  for (i = 1; i <= n; i++) {
    ch = substr($0, i, 1)
    if (ch in g) {
      out = out "<span color=\"" c[ch] "\">" g[ch] "</span>"
    }
  }
  print out
  fflush()
}
' < "$PIPE"
