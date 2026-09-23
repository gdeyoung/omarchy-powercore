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

## Roadmap (research-grounded)

v0.1.0 was scoped against what the community actually asks for, not guesswork.
Ranked ask inventory from Omarchy GitHub issues/discussions, r/omarchy, and
the reference plugins' lineages (Sep 2026):

Covered by v0.1.0 — the top four asks, which no single plugin served together:

1. **Charge limit / protection toggle** — the single most-recurring ask since
   Aug 2025 ([#627](https://github.com/omacom/omarchy/discussions/627),
   [#4474](https://github.com/omacom/omarchy/discussions/4474),
   [#10431](https://github.com/omacom/omarchy/discussions/10431));
   patcastle.power forked the stock widget *just* to add it.
2. **Per-source strategy** — profile + idle timings split by AC/battery
   ([#933](https://github.com/omacom/omarchy/discussions/933), 17 votes;
   auto profile switching shipped in Omarchy v3.4.0; idle split still open).
3. **Lid/clamshell control** — the second-biggest complaint cluster
   ([#1556](https://github.com/basecamp/omarchy/issues/1556),
   [#3871](https://github.com/basecamp/omarchy/discussions/3871), 45 votes).
4. **Live watts on the bar** — the efficiency-literate ask; Waybar's `{power}`
   precedent ([#2963](https://github.com/Alexays/Waybar/issues/2963)).

v2 candidates, in demand order (community evidence in parentheses):

- **Charge-guidance notifications** — plug at 10/30%, unplug at 80% (r/omarchy
  hand-rolled dotfiles; Waybar `states/events` is the feature floor).
- **Battery health readout** — capacity/wear %, cycle count (batctl got a
  97-upvote r/omarchy thread; omarchy-power-manager headlines it).
- **Low-battery warning hardening** — stock bug #8813 (critical toast never
  expires / replays after reboot) has 4 conflicting PRs; the first-party
  battery service coexists, so a hardened re-implementation is safe.
- **Time-remaining smoothing** — EMA over the gauge instead of UPower's raw
  jump (chronic distro-wide complaint, no Omarchy tool serves it).
- **Usage history / cost trends** — macOS-style day/week/month (Omabat, 36
  upvotes; energy-meter already proves the RAPL+amdgpu path).
- **Per-source lid actions** — powerplan's full matrix (suspend/ignore/lock/
  shutdown per source) instead of the single clamshell toggle.
- **Dual battery** — BAT0+BAT1 display ([#7067](https://github.com/basecamp/omarchy/discussions/7067),
  a waybar→Quickshell regression).
- **Not planned**: dGPU gating, TLP/tuned shims, RTC suspend-drain floor —
  real asks but wrong scope for a shell plugin (need root helpers; see
  powerplan's signed-package approach for the cost of that road).

Known ecosystem gaps we share: thresholds live in EC firmware and can revert
without boot/resume hooks (batctl ships udev+systemd persistence for this —
UPower's own service survives reboots, which is why PowerCore routes through
it rather than sysfs); and no rootless numeric-threshold path exists anywhere
in the ecosystem yet ([#10431](https://github.com/omacom/omarchy/discussions/10431)
is the open design).

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
