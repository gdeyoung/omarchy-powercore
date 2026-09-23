#!/bin/sh
# Power-draw sampler for gdeyoung.powercore. Prints ONE line:
#   "battery <watts>"  whole-system draw from the battery gauge (V*I)
#   "gpu <watts>"      amdgpu power1_average (SoC package, AC only)
#   "none"             nothing measurable right now
# Watts printed with one decimal. No state kept between calls.
#
# Primary source is the battery gauge: on battery it is the ONLY true
# whole-system draw measurement a laptop has (everything the machine draws
# flows through it). On AC the gauge reads ~0, so we fall back to the GPU
# sensor, which covers only the SoC package -- honest label applies.

for bat in /sys/class/power_supply/BAT*; do
  [ -r "$bat/status" ] || continue
  status=$(cat "$bat/status" 2>/dev/null)
  if [ "$status" = "Discharging" ] || [ "$status" = "Charging" ]; then
    if [ -r "$bat/power_now" ] && [ -s "$bat/power_now" ]; then
      pn=$(cat "$bat/power_now" 2>/dev/null)
      if [ -n "$pn" ] && [ "$pn" != "0" ]; then
        # power_now is microwatts
        echo "battery $(awk -v u="$pn" 'BEGIN { printf "%.1f", u / 1000000 }')"
        exit 0
      fi
    fi
    if [ -r "$bat/current_now" ] && [ -r "$bat/voltage_now" ]; then
      vn=$(cat "$bat/voltage_now" 2>/dev/null)
      cn=$(cat "$bat/current_now" 2>/dev/null)
      if [ -n "$vn" ] && [ -n "$cn" ] && [ "$cn" != "0" ]; then
        echo "battery $(awk -v v="$vn" -v c="$cn" 'BEGIN { printf "%.1f", v * c / 1000000000000 }')"
        exit 0
      fi
    fi
  fi
done

# AC fallback: amdgpu average power, microwatts.
for p in /sys/class/drm/card*/device/hwmon/hwmon*/power1_average; do
  [ -r "$p" ] || continue
  pa=$(cat "$p" 2>/dev/null)
  if [ -n "$pa" ] && [ "$pa" != "0" ]; then
    echo "gpu $(awk -v u="$pa" 'BEGIN { printf "%.1f", u / 1000000 }')"
    exit 0
  fi
done

echo "none"
