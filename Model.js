// Pure decisions for gdeyoung.powercore. No Qt imports: this file loads both
// from QML (import "Model.js" as Model) and from node (require) for the tests.
//
// Structure and several helpers adapted from leakz.betterpower (MIT,
// https://github.com/leakim34/omarchy-betterpower) and floscom.kbd-backlight
// (MIT, https://github.com/floscom/omarchy-kbd-backlight). The power-draw
// sampling model follows io.github.kevzakaria.energy-meter (MIT,
// https://github.com/kevzakaria/omarchy-energy-meter) with laptop battery
// gauge as the primary source instead of RAPL.

var SOURCES = ["battery", "ac"]
var PROFILES = ["power-saver", "balanced", "performance"]
var NEVER = 0
var MAX_DELAY = 86400

// Delay presets in seconds. 0 means never.
var DELAY_PRESETS = [60, 120, 300, 600, 900, 1800, 3600, NEVER]

// The idle service arms its monitor with the smaller of the two timings and a
// zero would fire at once, so a disabled step is written as a week and the
// whole cycle is switched off through stay-awake only when nothing fires.
var NEVER_IDLE_SECONDS = 604800

var DEFAULTS = {
  batteryProfile: "power-saver",
  batteryScreensaver: 120,
  batteryLock: 300,
  batterySleep: 600,
  batteryKbdBacklight: 0,
  acProfile: "performance",
  // Plugged in still locks, just lazier than on battery: never-lock on AC is
  // a posture change we refuse to ship as a default.
  acScreensaver: 300,
  acLock: 600,
  acSleep: NEVER,
  acKbdBacklight: 40,
  clamshell: true,
  barExtra: "percentage",
  barGauge: false,
  wattsRefreshSec: 4
}

// What the bar entry shows besides the icon. Right click cycles through them.
// "both" is the percentage and the live watts together.
var BAR_MODES = ["off", "percentage", "watts", "both"]
var GAUGE_LOW = 0.2

function normalizeBarMode(value, fallback) {
  var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
  return BAR_MODES.indexOf(s) >= 0 ? s : fallback
}

function barModeShows(mode) {
  var m = normalizeBarMode(mode, "off")
  return { percentage: m === "percentage" || m === "both", watts: m === "watts" || m === "both" }
}

function nextBarMode(mode, batteryPresent) {
  if (batteryPresent === false) return "off"
  var i = BAR_MODES.indexOf(normalizeBarMode(mode, "off"))
  return BAR_MODES[(i + 1) % BAR_MODES.length]
}

function normalizeBool(value, fallback) {
  if (typeof value === "boolean") return value
  if (typeof value === "number") return value !== 0
  var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
  if (s === "on" || s === "true" || s === "1" || s === "yes") return true
  if (s === "off" || s === "false" || s === "0" || s === "no") return false
  return fallback
}

// Geometry and tone of the bar-wide gauge for a battery fraction in [0,1].
// The fill runs from the bar's start edge over `fraction` of its length.
// `low` flags the urgent tone; `alpha` is the fill opacity against the bar
// background, slightly stronger when low so it stays visible.
function gaugeSpec(fraction, charging) {
  var f = Math.max(0, Math.min(1, Number(fraction) || 0))
  var low = !charging && f > 0 && f <= GAUGE_LOW
  return { fraction: f, low: low, alpha: low ? 0.34 : 0.22 }
}

// The plugin's own entry in shell.json: a bar layout item or a plugins[] item
// whose id matches. Settings are the other fields on that entry.
function findEntry(config, id) {
  if (!config || typeof config !== "object") return null
  var sections = ["left", "center", "right"]
  var layout = config.bar && config.bar.layout && typeof config.bar.layout === "object" ? config.bar.layout : {}
  for (var s = 0; s < sections.length; s++) {
    var arr = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
    for (var i = 0; i < arr.length; i++) {
      if (arr[i] && arr[i].id === id) return arr[i]
    }
  }
  var plugins = Array.isArray(config.plugins) ? config.plugins : []
  for (var j = 0; j < plugins.length; j++) {
    if (plugins[j] && plugins[j].id === id) return plugins[j]
  }
  return null
}

function sourceKey(source, field) {
  return source + field.charAt(0).toUpperCase() + field.slice(1)
}

function sourceLabel(source) {
  return source === "battery" ? "On battery" : "Plugged in"
}

// What this machine offers, decided once from UPower's display device, the lid
// probe and the LED probe, so the service, the panel and the bar hide the same
// things. A desktop has one source, no battery hero, no charge control, no
// gauge and no keyboard backlight.
function hardware(batteryPresent, lidPresent, kbdPresent) {
  var battery = !!batteryPresent
  return {
    battery: battery,
    lid: !!lidPresent,
    kbd: !!kbdPresent,
    sources: battery ? SOURCES.slice() : ["ac"],
    chargeControl: battery,
    clamshell: !!lidPresent,
    gauge: battery,
    draw: true
  }
}

// Output of `ls /proc/acpi/button/lid`: one entry per lid switch, empty when
// the machine has none.
function parseLidProbe(raw) {
  return String(raw || "").trim().length > 0
}

// Section header per source. The NOW marker only means something when there is
// another source to switch to.
function sourceHeader(source, current, sources) {
  var list = Array.isArray(sources) ? sources : SOURCES
  var label = sourceLabel(source).toUpperCase()
  return list.length > 1 && current ? label + "  \u00b7  NOW" : label
}

function normalizeDelay(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback
  var n = Number(value)
  if (!isFinite(n) || n < 0) return fallback
  return Math.min(MAX_DELAY, Math.floor(n))
}

function normalizeProfile(value, fallback, available) {
  var list = Array.isArray(available) && available.length > 0 ? available : PROFILES
  var v = String(value === undefined || value === null ? "" : value)
  if (list.indexOf(v) !== -1) return v
  if (list.indexOf(fallback) !== -1) return fallback
  return list.indexOf("balanced") !== -1 ? "balanced" : list[0]
}

// Keyboard backlight percent for a source: whole percent, 0-100.
function normalizeKbdPercent(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback
  var n = Number(value)
  if (!isFinite(n) || n < 0) return fallback
  return Math.min(100, Math.floor(n))
}

// Watts refresh: seconds between draw samples.
function normalizeWattsRefresh(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback
  var n = Number(value)
  if (!isFinite(n) || n < 2) return fallback
  return Math.min(60, Math.floor(n))
}

// Every setting the plugin reads, coerced to a valid value. `available` is the
// profile list reported by omarchy-powerprofiles-list, or empty when unknown.
function normalizeSettings(raw, available) {
  var s = raw && typeof raw === "object" ? raw : {}
  var out = {}
  for (var i = 0; i < SOURCES.length; i++) {
    var src = SOURCES[i]
    var p = sourceKey(src, "profile")
    out[p] = normalizeProfile(s[p], DEFAULTS[p], available)
    var fields = ["screensaver", "lock", "sleep", "kbdBacklight"]
    for (var j = 0; j < fields.length; j++) {
      var k = sourceKey(src, fields[j])
      if (fields[j] === "kbdBacklight")
        out[k] = normalizeKbdPercent(s[k], DEFAULTS[k])
      else
        out[k] = normalizeDelay(s[k], DEFAULTS[k])
    }
  }
  out.clamshell = normalizeBool(s.clamshell, DEFAULTS.clamshell)
  // Legacy betterpower `showPercentage: true` reads as the percentage mode;
  // its `barMode` values (off/percentage/gauge/both) map onto our split
  // barExtra + barGauge pair.
  var legacyMode = String(s.barMode === undefined || s.barMode === null ? "" : s.barMode).trim().toLowerCase()
  var legacy = normalizeBool(s.showPercentage, false) ? "percentage" : DEFAULTS.barExtra
  if (legacyMode === "percentage" || legacyMode === "both") legacy = "percentage"
  out.barExtra = normalizeBarMode(s.barExtra, legacy)
  var legacyGauge = legacyMode === "gauge" || legacyMode === "both"
  out.barGauge = normalizeBool(s.barGauge, legacyGauge ? true : DEFAULTS.barGauge)
  out.wattsRefreshSec = normalizeWattsRefresh(s.wattsRefreshSec, DEFAULTS.wattsRefreshSec)
  return out
}

// The strategy the service must apply for one source.
function strategyFor(source, settings) {
  var s = normalizeSettings(settings)
  var lock = s[sourceKey(source, "lock")]
  return {
    source: source,
    profile: s[sourceKey(source, "profile")],
    screensaver: s[sourceKey(source, "screensaver")],
    lock: lock,
    // Sleep is armed only after the lock fired, so never-lock implies never-sleep.
    sleep: lock === NEVER ? NEVER : s[sourceKey(source, "sleep")],
    kbdBacklight: s[sourceKey(source, "kbdBacklight")],
    stayAwake: lock === NEVER && s[sourceKey(source, "screensaver")] === NEVER
  }
}

// What the service writes for one strategy: the idle keys of shell.json and
// whether the idle cycle must be disabled altogether.
function idleConfigFor(strategy) {
  var screensaver = strategy.screensaver === NEVER ? NEVER_IDLE_SECONDS : strategy.screensaver
  var lock = strategy.lock === NEVER ? NEVER_IDLE_SECONDS : strategy.lock
  return { screensaver: screensaver, lock: lock, stayAwake: !!strategy.stayAwake }
}

function sameIdleConfig(a, b) {
  if (!a || !b) return false
  return a.screensaver === b.screensaver && a.lock === b.lock && a.stayAwake === b.stayAwake
}

// UPower's ChargeThresholdSettingsSupported bitmask.
var CHARGE_START = 1
var CHARGE_END = 2
var CHARGE_FIRMWARE = 4

// Output of the charge probe script: "key\tvalue" lines from busctl.
function parseChargeState(raw) {
  var out = { supported: false, settings: 0, enabled: false, start: 0, end: 0 }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    var key = String(parts[0] || "").trim()
    var value = String(parts[1] || "").trim()
    if (key === "supported") out.supported = value === "true"
    else if (key === "settings") out.settings = Number(value) || 0
    else if (key === "enabled") out.enabled = value === "true"
    else if (key === "start") out.start = Number(value) || 0
    else if (key === "end") out.end = Number(value) || 0
  }
  return out
}

// What the panel shows for a charge state: whether the control exists and how
// to describe what enabling it does on this hardware.
function chargeCapability(state) {
  var s = state || {}
  var mask = Number(s.settings) || 0
  var firmware = (mask & CHARGE_FIRMWARE) !== 0
  var end = (mask & CHARGE_END) !== 0
  var start = (mask & CHARGE_START) !== 0
  if (!s.supported || (!firmware && !end)) {
    return { available: false, mode: "none", description: "This battery does not report charge control." }
  }
  if (end) {
    var range = s.enabled && Number(s.end) > 0
      ? (start && Number(s.start) > 0 ? "Charges between " + s.start + "% and " + s.end + "%." : "Charging stops at " + s.end + "%.")
      : "Stops charging before full to preserve battery life."
    return { available: true, mode: "threshold", description: range }
  }
  return {
    available: true,
    mode: "firmware",
    description: "The firmware limits the charge to preserve battery life (conservation mode)."
  }
}

// Internal panels are eDP, LVDS or DSI connectors; anything else is external.
function isExternalScreen(name) {
  return !/^(eDP|LVDS|DSI)-/i.test(String(name || ""))
}

function hasExternalScreen(names) {
  var list = Array.isArray(names) ? names : []
  for (var i = 0; i < list.length; i++) {
    if (isExternalScreen(list[i])) return true
  }
  return false
}

// Whether the lid inhibitor must be held, and the sentence the panel shows.
function lidBehavior(clamshell, external, lid) {
  if (lid === false) {
    return { inhibit: false, description: "This machine has no lid." }
  }
  if (!external) {
    return { inhibit: false, description: "No external screen: closing the lid locks and follows the system's lid setting." }
  }
  if (clamshell) {
    return { inhibit: true, description: "Closing the lid keeps the session running on the external screen." }
  }
  return { inhibit: false, description: "Closing the lid follows the system's lid setting." }
}

// ---- Battery hero, ported from the first-party power panel so both panels
// read the same way.

// Output of `omarchy-battery-status --shell`: "key\tvalue" lines.
function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return next
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, Number(device.percentage) || 0)) : 0
}

// `states` carries the UPowerDeviceState enum values the QML side knows.
function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d.isPresent && !onBattery)) return false
  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false
  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

var CHARGING_ICONS = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
var LEVEL_ICONS = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]

function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return "󰚥"
  var index = Math.max(0, Math.min(9, Math.floor(batteryFraction(d) * 10)))
  if (chargeThresholdActive(d, onBattery, states)) return LEVEL_ICONS[index]
  if (states && d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return CHARGING_ICONS[index]
  return LEVEL_ICONS[index]
}

function heroTitle(batteryPresent) {
  return batteryPresent ? "Battery" : "Power"
}

function heroFallbackStatus(device, onBattery, states, activeProfile) {
  if (device && device.isPresent) return modeLabel(device, onBattery, states)
  return activeProfile ? profileLabel(activeProfile) : "Plugged in"
}

function modeLabel(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return "No battery"
  if (chargeThresholdActive(d, onBattery, states)) return "Threshold"
  if (onBattery) return "On battery"
  if (batteryFraction(d) >= 1) return "Fully charged"
  return "Charging"
}

var CHARGING_PHRASES = ["Pumping power", "Injecting electrons", "Pouring juice", "Amassing watts", "Hoarding joules", "Topping reserves", "Soaking amps"]
var ON_BATTERY_PHRASES = ["Slurping power", "Spending joules", "Draining watts", "Burning electrons", "Sipping juice", "Munching reserves"]

function chargeLimitLabel(chargeState, thresholdText) {
  var s = chargeState || {}
  if (!s.supported) return "-"
  if (!s.enabled) return "Off"
  if (thresholdText) return String(thresholdText)
  if (Number(s.end) > 0) return s.end + "%"
  return "On"
}

// ---- Power draw. The sampler script prints one line:
//   "battery <watts>"   - whole-system draw from the battery gauge
//   "gpu <watts>"       - amdgpu power1_average while on AC
//   "none"              - nothing measurable right now
// Watts are whole units with one decimal of precision from the script.
function parseDrawSample(raw) {
  var parts = String(raw || "").trim().split(/\s+/)
  var mode = String(parts[0] || "")
  var watts = Number(parts[1])
  if (mode !== "battery" && mode !== "gpu") return null
  if (!isFinite(watts) || watts < 0) return null
  return { mode: mode, watts: Math.round(watts * 10) / 10 }
}

function drawMethodLabel(mode) {
  if (mode === "battery") return "Battery gauge (whole system)"
  if (mode === "gpu") return "GPU sensor (SoC only, on AC)"
  return ""
}

// Watts text for the bar: compact, one decimal below 100, whole above.
// The threshold is checked on the rounded value so 99.96 reads "100 W", not
// "100.0 W".
function formatWatts(watts) {
  var n = Number(watts)
  if (!isFinite(n) || n <= 0) return "0 W"
  var whole = Math.round(n)
  if (whole < 100) return (Math.round(n * 10) / 10).toFixed(1) + " W"
  return whole + " W"
}

// ---- Keyboard backlight. Percent <-> raw device units; `max` is the LED's
// own max_brightness (255 on applesmc, 3 on this ASUS), so the plugin never
// assumes a scale. Round-trip percent->raw->percent may lose resolution on a
// 4-step LED; the panel shows the percent that was set, the hardware gets the
// nearest step.
function percentToRaw(percent, max) {
  var m = Math.max(1, Math.round(Number(max) || 1))
  return Math.round(clampPercent(percent) / 100 * m)
}

function rawToPercent(raw, max) {
  var m = Math.max(1, Math.round(Number(max) || 1))
  return clampPercent(Math.round(Number(raw) || 0) / m * 100)
}

function clamp(value, low, high) {
  var n = Number(value)
  if (isNaN(n)) return low
  return n < low ? low : (n > high ? high : n)
}

function clampPercent(value) {
  return Math.round(clamp(value, 0, 100))
}

// Detection prints the LED directory, one per line, possibly blank.
function parseLedProbe(raw) {
  return String(raw || "").replace(/^\/sys\/class\/leds\//, "").replace(/\/+$/, "").replace(/^\s+|\s+$/g, "")
}

function ledName(ledPath) {
  var path = String(ledPath || "").replace(/\/+$/, "")
  var cut = path.lastIndexOf("/")
  return cut === -1 ? path : path.slice(cut + 1)
}

// Dropdown options for a source's keyboard backlight percent. On a coarse LED
// (max <= 8 steps) the options are the device's own steps; otherwise round
// percents. The current value is always present.
function kbdOptions(maxRaw, current) {
  var max = Math.max(1, Math.round(Number(maxRaw) || 1))
  var cur = clampPercent(current)
  var out = []
  if (max <= 8) {
    var names = ["Off", "Low", "Medium", "High", "Higher", "Higher still", "Almost full", "Near max"]
    for (var i = 0; i <= max; i++) {
      var label = i === 0 ? "Off" : (i === max ? "Full" : (names[i] || String(i)))
      out.push({ value: String(rawToPercent(i, max)), label: label })
    }
  } else {
    var steps = [0, 20, 40, 60, 80, 100]
    for (var j = 0; j < steps.length; j++)
      out.push({ value: String(steps[j]), label: steps[j] === 0 ? "Off" : steps[j] + "%" })
  }
  var vals = []
  for (var k = 0; k < out.length; k++) vals.push(Number(out[k].value))
  if (vals.indexOf(cur) === -1) out.push({ value: String(cur), label: cur === 0 ? "Off" : cur + "%" })
  out.sort(function (a, b) {
    return Number(a.value) - Number(b.value)
  })
  return out
}

// Next coarse step (in percent) for the bar's middle-click cycle, from the
// device's current raw level.
function nextKbdStep(raw, max) {
  var m = Math.max(1, Math.round(Number(max) || 1))
  var r = Math.max(0, Math.min(m, Math.round(Number(raw) || 0)))
  return rawToPercent(r >= m ? 0 : r + 1, m)
}

function delayLabel(seconds) {
  var n = normalizeDelay(seconds, NEVER)
  if (n === NEVER) return "Never"
  if (n < 60) return n + " s"
  if (n % 3600 === 0) return (n / 3600) + " h"
  if (n % 60 === 0) return (n / 60) + " min"
  return Math.floor(n / 60) + " min " + (n % 60) + " s"
}

function delayOptions(current) {
  var list = DELAY_PRESETS.slice()
  var n = normalizeDelay(current, NEVER)
  if (list.indexOf(n) === -1) list.push(n)
  list.sort(function (a, b) {
    if (a === NEVER) return 1
    if (b === NEVER) return -1
    return a - b
  })
  var out = []
  for (var i = 0; i < list.length; i++) out.push({ value: String(list[i]), label: delayLabel(list[i]) })
  return out
}

// Output of `omarchy-powerprofiles-list --active-state`: one "name\t1|0" per line.
function parseProfiles(raw) {
  var profiles = []
  var active = ""
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    var name = String(parts[0] || "").trim()
    if (!name) continue
    profiles.push(name)
    if (String(parts[1] || "").trim() === "1") active = name
  }
  return { profiles: profiles, active: active }
}

function profileOptions(profiles) {
  var list = Array.isArray(profiles) && profiles.length > 0 ? profiles : PROFILES
  var out = []
  for (var i = 0; i < list.length; i++) {
    out.push({ value: list[i], label: profileLabel(list[i]), icon: profileIcon(list[i]) })
  }
  return out
}

function profileIcon(name) {
  if (name === "performance") return "󰓅"
  if (name === "power-saver") return "󰌪"
  return "󰾅"
}

function profileLabel(name) {
  if (name === "power-saver") return "Eco"
  return String(name).charAt(0).toUpperCase() + String(name).slice(1)
}

if (typeof module !== "undefined") {
  module.exports = {
    SOURCES: SOURCES,
    PROFILES: PROFILES,
    NEVER: NEVER,
    DELAY_PRESETS: DELAY_PRESETS,
    NEVER_IDLE_SECONDS: NEVER_IDLE_SECONDS,
    idleConfigFor: idleConfigFor,
    CHARGE_START: CHARGE_START,
    CHARGE_END: CHARGE_END,
    CHARGE_FIRMWARE: CHARGE_FIRMWARE,
    isExternalScreen: isExternalScreen,
    hasExternalScreen: hasExternalScreen,
    lidBehavior: lidBehavior,
    parseKeyValue: parseKeyValue,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel,
    CHARGING_PHRASES: CHARGING_PHRASES,
    ON_BATTERY_PHRASES: ON_BATTERY_PHRASES,
    chargeLimitLabel: chargeLimitLabel,
    parseChargeState: parseChargeState,
    chargeCapability: chargeCapability,
    sameIdleConfig: sameIdleConfig,
    DEFAULTS: DEFAULTS,
    findEntry: findEntry,
    sourceKey: sourceKey,
    sourceLabel: sourceLabel,
    hardware: hardware,
    parseLidProbe: parseLidProbe,
    sourceHeader: sourceHeader,
    heroTitle: heroTitle,
    heroFallbackStatus: heroFallbackStatus,
    normalizeDelay: normalizeDelay,
    normalizeProfile: normalizeProfile,
    normalizeBool: normalizeBool,
    normalizeKbdPercent: normalizeKbdPercent,
    normalizeWattsRefresh: normalizeWattsRefresh,
    BAR_MODES: BAR_MODES,
    GAUGE_LOW: GAUGE_LOW,
    normalizeBarMode: normalizeBarMode,
    nextBarMode: nextBarMode,
    gaugeSpec: gaugeSpec,
    barModeShows: barModeShows,
    normalizeSettings: normalizeSettings,
    strategyFor: strategyFor,
    parseDrawSample: parseDrawSample,
    drawMethodLabel: drawMethodLabel,
    formatWatts: formatWatts,
    percentToRaw: percentToRaw,
    rawToPercent: rawToPercent,
    clampPercent: clampPercent,
    parseLedProbe: parseLedProbe,
    ledName: ledName,
    kbdOptions: kbdOptions,
    nextKbdStep: nextKbdStep,
    delayLabel: delayLabel,
    delayOptions: delayOptions,
    parseProfiles: parseProfiles,
    profileOptions: profileOptions,
    profileIcon: profileIcon,
    profileLabel: profileLabel
  }
}
