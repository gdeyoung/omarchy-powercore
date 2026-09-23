# PowerCore (gdeyoung.powercore)

A battery and power bar widget for [Omarchy](https://omarchy.org/) that
replaces the stock `omarchy.power` widget: per-source power strategy, battery
protection, clamshell lid control, per-source keyboard backlight, and live
power draw in watts — one icon, one panel.

```
Per power source (plugged in / on battery), independently:
  power profile    power-saver · balanced · performance (powerprofilesctl)
  screensaver      seconds, or never
  lock             seconds, or never
  sleep            seconds after the lock fired, or never
  keyboard backlight  off/low/… per source, re-applied on plug events

Plus, always:
  battery protection   UPower EnableChargeThreshold toggle (polkit, no root)
  clamshell            keep running with the lid closed on an external screen
  live power draw      watts on the bar, from the battery gauge (true
                       whole-system draw on battery) or the GPU sensor on AC
  bar-wide gauge       optional battery fill painted across the whole bar
```

## Why

Four community plugins each do one slice of this well. PowerCore is the
union, built for a laptop whose hardware has no ambient light sensor and a
4-step keyboard LED — so the keyboard backlight is per-power-source instead
of ALS-driven, and power draw leads with the battery gauge because that is
the only true whole-system measurement a laptop has.

Credits and sources, all MIT:

- **leakz.betterpower** — the base. Policy-engine architecture (headless
  service owns every side effect, pure Model.js for logic, panel only reads
  state), per-source strategy, UPower charge-threshold handling, clamshell
  inhibitor, bar-wide gauge. <https://github.com/leakim34/omarchy-betterpower>
- **valleytheknight.powerplan** — lid-close action handling reference.
  <https://github.com/ValleytheKnight/omarchy-powerplan-widget>
- **floscom.kbd-backlight** — keyboard backlight service pattern
  (brightnessctl via logind, ramping, single-writer LED discipline).
  <https://github.com/floscom/omarchy-kbd-backlight>
- **io.github.kevzakaria.energy-meter** — power sampling honesty (label what
  is measured vs estimated). <https://github.com/kevzakaria/omarchy-energy-meter>

## Install

```
omarchy plugin add https://github.com/gdeyoung/omarchy-powercore.git --enable
omarchy bar put gdeyoung.powercore --section right --after omarchy.power
omarchy bar remove omarchy.power   # optional: drop the stock widget
```

No root, no daemon, no udev rule. Everything runs inside the shell process
with user privileges: profiles via `omarchy-powerprofiles-set`, charge limit
via UPower D-Bus (polkit allows the active session), keyboard backlight via
`brightnessctl` (logind fallback), lid via a logind inhibitor held by a child
process that dies with the shell.

## Bar interactions

- **Left click** — open the panel
- **Right click** — cycle the extra label: nothing → percentage → watts → both
- **Middle click** — cycle the keyboard backlight through its steps
- Tooltip names the current power source

## Panel

Hero (icon, status, percentage) → progress bar → battery stats and live
draw (with an honest source label) → battery protection toggle → clamshell
toggle → one section per power source: profile buttons, screensaver/lock/
sleep dropdowns, keyboard backlight dropdown. Full keyboard navigation like
the stock panel.

## Power draw, honestly

On battery the draw is the battery gauge's V×I — everything the machine
draws flows through it, so it is the whole system, charger excluded. On AC
the battery gauge reads ~0, so the widget falls back to the amdgpu package
power sensor, which covers only the SoC: the bar shows the number and the
panel says "GPU sensor (SoC only, on AC)". RAPL is root-gated on this
machine (CVE-2020-8694) and deliberately not pried open for a widget.

## Battery protection on ASUS

The firmware fixes the threshold window (75–80% here); UPower exposes only
`EnableChargeThreshold` — there is no writable numeric threshold API — so
the control is a toggle and the panel shows the window the firmware will
apply. ThinkPad/Framework machines with sysfs `charge_control_end_threshold`
get the same toggle through UPower's threshold mode.

## Development

```
node --test tests/        # pure-logic tests (Model.js has no Qt imports)
```

Deploy a local checkout: copy the repo to
`~/.config/omarchy/plugins/gdeyoung.powercore/` and
`omarchy restart shell`. Check the log:
`grep -a powercore $(ls -td /run/user/$UID/quickshell/by-id/* | head -1)/log.qslog`.

## License

MIT
