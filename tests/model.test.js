// Node tests for Model.js — pure logic only, mirrors the QML import.
// Run: node --test tests/
const test = require("node:test")
const assert = require("node:assert")
const Model = require("../Model.js")

// ---- strategy per source

test("strategy applies per-source profile, idle, and kbd backlight", () => {
  const s = Model.normalizeSettings(Model.DEFAULTS)
  const batt = Model.strategyFor("battery", s)
  const ac = Model.strategyFor("ac", s)
  assert.equal(batt.profile, "power-saver")
  assert.equal(ac.profile, "performance")
  assert.equal(batt.kbdBacklight, 0)
  assert.equal(ac.kbdBacklight, 40)
  assert.equal(batt.lock, 300)
  // AC still locks by default: never-lock-on-AC is not a default we ship.
  assert.equal(ac.lock, 600)
  assert.equal(ac.screensaver, 300)
})

test("never-lock implies never-sleep", () => {
  const s = Model.normalizeSettings({ acLock: 0, acSleep: 600 })
  const ac = Model.strategyFor("ac", s)
  assert.equal(ac.sleep, Model.NEVER)
})

test("stayAwake only when nothing fires", () => {
  const s = Model.normalizeSettings({ acLock: 0, acScreensaver: 0, acSleep: 0 })
  assert.equal(Model.strategyFor("ac", s).stayAwake, true)
  const s2 = Model.normalizeSettings({ acLock: 0, acScreensaver: 120 })
  assert.equal(Model.strategyFor("ac", s2).stayAwake, false)
})

test("idleConfigFor maps never to the week sentinel", () => {
  const s = Model.normalizeSettings({ acLock: 0, acScreensaver: 0 })
  const cfg = Model.idleConfigFor(Model.strategyFor("ac", s))
  assert.equal(cfg.lock, Model.NEVER_IDLE_SECONDS)
  assert.equal(cfg.stayAwake, true)
})

// ---- settings normalization

test("legacy betterpower showPercentage migrates to barExtra percentage", () => {
  const s = Model.normalizeSettings({ showPercentage: true })
  assert.equal(s.barExtra, "percentage")
  const s2 = Model.normalizeSettings({})
  assert.equal(s2.barExtra, "percentage") // our own default
})

test("legacy betterpower barMode gauge keeps the gauge flag", () => {
  const s = Model.normalizeSettings({ barMode: "gauge" })
  assert.equal(s.barGauge, true)
  const s2 = Model.normalizeSettings({ barMode: "both" })
  assert.equal(s2.barExtra, "percentage")
  assert.equal(s2.barGauge, true)
})

test("barExtra only accepts known modes", () => {
  const s = Model.normalizeSettings({ barExtra: "watts" })
  assert.equal(s.barExtra, "watts")
  const s2 = Model.normalizeSettings({ barExtra: "bogus" })
  assert.equal(s2.barExtra, "percentage")
})

test("kbdBacklight clamps to 0-100 integers", () => {
  const s = Model.normalizeSettings({ acKbdBacklight: 140, batteryKbdBacklight: -3 })
  assert.equal(s.acKbdBacklight, 100)
  assert.equal(s.batteryKbdBacklight, 0)
  const s2 = Model.normalizeSettings({ acKbdBacklight: "66" })
  assert.equal(s2.acKbdBacklight, 66)
})

test("wattsRefresh clamps to 2-60", () => {
  assert.equal(Model.normalizeSettings({ wattsRefreshSec: 1 }).wattsRefreshSec, 4)
  assert.equal(Model.normalizeSettings({ wattsRefreshSec: 0 }).wattsRefreshSec, 4)
  assert.equal(Model.normalizeSettings({ wattsRefreshSec: 90 }).wattsRefreshSec, 60)
  assert.equal(Model.normalizeSettings({ wattsRefreshSec: "7" }).wattsRefreshSec, 7)
})

test("normalizeBool accepts On/Off strings and booleans", () => {
  assert.equal(Model.normalizeBool("On", false), true)
  assert.equal(Model.normalizeBool("off", true), false)
  assert.equal(Model.normalizeBool(1, false), true)
  assert.equal(Model.normalizeBool(undefined, true), true)
})

// ---- bar modes and gauge

test("nextBarMode cycles through all four modes", () => {
  assert.equal(Model.nextBarMode("off", true), "percentage")
  assert.equal(Model.nextBarMode("percentage", true), "watts")
  assert.equal(Model.nextBarMode("watts", true), "both")
  assert.equal(Model.nextBarMode("both", true), "off")
})

test("barModeShows splits percentage and watts", () => {
  const shows = Model.barModeShows("both")
  assert.equal(shows.percentage, true)
  assert.equal(shows.watts, true)
  const shows2 = Model.barModeShows("watts")
  assert.equal(shows2.percentage, false)
  assert.equal(shows2.watts, true)
})

test("gaugeSpec flags low only when discharging under 20%", () => {
  assert.equal(Model.gaugeSpec(0.15, false).low, true)
  assert.equal(Model.gaugeSpec(0.15, true).low, false)
  assert.equal(Model.gaugeSpec(0.5, false).low, false)
  assert.equal(Model.gaugeSpec(0, false).low, false)
  assert.ok(Model.gaugeSpec(1.5, false).fraction <= 1)
})

// ---- power draw

test("parseDrawSample accepts battery and gpu lines only", () => {
  assert.deepEqual(Model.parseDrawSample("battery 12.34"), { mode: "battery", watts: 12.3 })
  assert.deepEqual(Model.parseDrawSample("gpu 9"), { mode: "gpu", watts: 9 })
  assert.equal(Model.parseDrawSample("none"), null)
  assert.equal(Model.parseDrawSample(""), null)
  assert.equal(Model.parseDrawSample("battery -5"), null)
  assert.equal(Model.parseDrawSample("battery abc"), null)
})

test("formatWatts keeps a decimal below 100, whole above", () => {
  assert.equal(Model.formatWatts(12.34), "12.3 W")
  assert.equal(Model.formatWatts(99.96), "100 W")
  assert.equal(Model.formatWatts(123.4), "123 W")
  assert.equal(Model.formatWatts(0), "0 W")
  assert.equal(Model.formatWatts(-1), "0 W")
})

test("drawMethodLabel names the source honestly", () => {
  assert.equal(Model.drawMethodLabel("battery"), "Battery gauge (whole system)")
  assert.equal(Model.drawMethodLabel("gpu"), "GPU sensor (SoC only, on AC)")
})

// ---- keyboard backlight scale

test("percentToRaw and rawToPercent round-trip on a 4-step LED", () => {
  // max=3: 0%->0, 33%->1, 66%->2, 100%->3
  assert.equal(Model.percentToRaw(0, 3), 0)
  assert.equal(Model.percentToRaw(100, 3), 3)
  assert.equal(Model.percentToRaw(50, 3), 2)
  assert.equal(Model.rawToPercent(2, 3), 67)
  assert.equal(Model.rawToPercent(0, 3), 0)
  assert.equal(Model.rawToPercent(3, 3), 100)
})

test("percentToRaw clamps out-of-range percent", () => {
  assert.equal(Model.percentToRaw(150, 3), 3)
  assert.equal(Model.percentToRaw(-10, 255), 0)
})

test("parseLedProbe strips the sysfs prefix", () => {
  assert.equal(Model.parseLedProbe("/sys/class/leds/asus::kbd_backlight\n"), "asus::kbd_backlight")
  assert.equal(Model.parseLedProbe(""), "")
})

test("ledName takes the last path segment", () => {
  assert.equal(Model.ledName("/sys/class/leds/asus::kbd_backlight"), "asus::kbd_backlight")
  assert.equal(Model.ledName("thinkpad_acpi::kbd_backlight"), "thinkpad_acpi::kbd_backlight")
})

// ---- hardware capability

test("hardware reports what each machine offers", () => {
  const laptop = Model.hardware(true, true, true)
  assert.deepEqual(laptop.sources, ["battery", "ac"])
  assert.equal(laptop.kbd, true)
  const desktop = Model.hardware(false, false, false)
  assert.deepEqual(desktop.sources, ["ac"])
  assert.equal(desktop.chargeControl, false)
  assert.equal(desktop.gauge, false)
})

// ---- charge capability

test("chargeCapability distinguishes threshold and firmware modes", () => {
  const threshold = Model.chargeCapability({ supported: true, settings: 2, enabled: true, start: 75, end: 80 })
  assert.equal(threshold.available, true)
  assert.equal(threshold.mode, "threshold")
  // settings bitmask 2 = END only, so the range text names the stop point.
  assert.ok(threshold.description.indexOf("80") >= 0)
  const ranged = Model.chargeCapability({ supported: true, settings: 3, enabled: true, start: 75, end: 80 })
  assert.ok(ranged.description.indexOf("75") >= 0 && ranged.description.indexOf("80") >= 0)
  const firmware = Model.chargeCapability({ supported: true, settings: 4, enabled: false })
  assert.equal(firmware.mode, "firmware")
  const none = Model.chargeCapability({ supported: false, settings: 0 })
  assert.equal(none.available, false)
})

test("parseChargeState reads busctl tab lines", () => {
  const state = Model.parseChargeState("supported\ttrue\nsettings\t2\nenabled\tfalse\nstart\t75\nend\t80\n")
  assert.deepEqual(state, { supported: true, settings: 2, enabled: false, start: 75, end: 80 })
})

// ---- lid behavior

test("lidBehavior holds the inhibitor only for clamshell with external screen", () => {
  assert.equal(Model.lidBehavior(true, true, true).inhibit, true)
  assert.equal(Model.lidBehavior(false, true, true).inhibit, false)
  assert.equal(Model.lidBehavior(true, false, true).inhibit, false)
  assert.equal(Model.lidBehavior(true, true, false).inhibit, false)
})

// ---- profiles

test("parseProfiles reads the list and the active flag", () => {
  const parsed = Model.parseProfiles("power-saver\t0\nbalanced\t0\nperformance\t1\n")
  assert.deepEqual(parsed.profiles, ["power-saver", "balanced", "performance"])
  assert.equal(parsed.active, "performance")
})

test("normalizeProfile prefers a valid fallback, else balanced", () => {
  // Fallback valid: it wins over an unknown value.
  assert.equal(Model.normalizeProfile("turbo", "power-saver", ["power-saver", "balanced", "performance"]), "power-saver")
  // Fallback not in the list either: balanced wins.
  assert.equal(Model.normalizeProfile("turbo", "nope", ["power-saver", "balanced", "performance"]), "balanced")
  assert.equal(Model.normalizeProfile(undefined, "power-saver", []), "power-saver")
})

// ---- delays

test("delayOptions includes the current value and sorts never last", () => {
  const opts = Model.delayOptions(240)
  const values = opts.map((o) => Number(o.value))
  assert.ok(values.indexOf(240) >= 0)
  assert.equal(values[values.length - 1], Model.NEVER)
})

test("delayLabel formats human timings", () => {
  assert.equal(Model.delayLabel(0), "Never")
  assert.equal(Model.delayLabel(45), "45 s")
  assert.equal(Model.delayLabel(120), "2 min")
  assert.equal(Model.delayLabel(3600), "1 h")
})

// ---- findEntry

test("findEntry locates the plugin entry in bar layout or plugins list", () => {
  const config = {
    bar: { layout: { right: [{ id: "other" }, { id: "gdeyoung.powercore", barExtra: "watts" }] } },
    plugins: [{ id: "x" }]
  }
  const entry = Model.findEntry(config, "gdeyoung.powercore")
  assert.equal(entry.barExtra, "watts")
  assert.equal(Model.findEntry(config, "missing"), null)
})
