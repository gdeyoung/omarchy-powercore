import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Wayland
import "Model.js" as Model

// Policy engine for gdeyoung.powercore. Loaded by the shell at startup as a
// headless service. It owns every side effect (processes, D-Bus, inhibitors)
// and is the single writer of the plugin's settings; the panel only reads its
// state and calls its functions.
//
// Adapted from leakz.betterpower (MIT, github.com/leakim34/omarchy-betterpower)
// with two additions: per-source keyboard backlight (from the floscom.kbd-backlight
// pattern) and live power-draw sampling (powerdraw.sh).
//
// Three rules keep it from fighting the shell:
// - Nothing is written before the settle period after startup has passed;
//   the state files, shell.json and the stay-awake file already hold what was
//   applied last time.
// - Settings are read from the shell's live config in a change handler, not a
//   binding, because every write below changes that config.
// - Syncs run through Qt.callLater so a write never re-enters itself.
Item {
  id: root

  // Injected by the shell loader.
  property var shell: null

  readonly property string pluginId: "gdeyoung.powercore"
  readonly property string home: Quickshell.env("HOME")
  readonly property string powerProfilesStateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/powerprofiles"
  readonly property bool onBattery: UPower.onBattery
  readonly property string source: onBattery ? "battery" : "ac"
  readonly property var device: UPower.displayDevice
  readonly property bool batteryPresent: !!(device && device.isPresent)
  // False until the lid probe answered: fail closed, no inhibitor on a guess.
  property bool lidPresent: false
  property bool lidProbed: false
  // Keyboard backlight LED, discovered once. Empty name = no LED.
  property string kbdLedName: ""
  property int kbdLedMax: 0
  property bool kbdProbed: false
  readonly property bool kbdAvailable: kbdProbed && kbdLedName !== "" && kbdLedMax > 0
  readonly property var hardware: Model.hardware(batteryPresent, lidPresent, kbdAvailable)

  property var rawSettings: ({})
  property var profiles: []
  property string activeProfile: ""
  readonly property var settings: Model.normalizeSettings(rawSettings, profiles)
  readonly property var strategy: Model.strategyFor(source, settings)

  property bool settled: false
  property var appliedProfile: ({})
  property var appliedIdle: null
  property int appliedKbdPercent: -1
  property var queue: []
  property string lastEvent: "starting"
  property string lastEventAt: ""

  function log(event, details) {
    var suffix = details === undefined || details === null || details === "" ? "" : ": " + String(details);
    root.lastEventAt = new Date().toISOString();
    root.lastEvent = event + suffix;
    console.log(pluginId + " " + root.lastEventAt + " " + root.lastEvent);
  }

  // ---------------------------------------------------------------- settings

  function readSettings() {
    var entry = shell ? Model.findEntry(shell.shellConfig, pluginId) : null;
    var next = entry || ({});
    if (JSON.stringify(next) === JSON.stringify(rawSettings))
      return;
    rawSettings = next;
    scheduleSync();
  }

  function saveSettings(patch) {
    var merged = {};
    for (var k in rawSettings)
      merged[k] = rawSettings[k];
    for (var p in patch) {
      if (patch[p] === undefined)
        delete merged[p];
      else
        merged[p] = patch[p];
    }
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(pluginId, merged);
    else
      log("settings-not-persisted", "shell has no updateEntryInline");
  }

  Connections {
    target: root.shell
    function onShellConfigChanged() {
      root.readSettings();
    }
  }

  // Remember what is already in effect, then start syncing on changes.
  function settle() {
    if (settled)
      return;
    readSettings();
    var applied = {};
    for (var i = 0; i < hardware.sources.length; i++)
      applied[hardware.sources[i]] = settings[Model.sourceKey(hardware.sources[i], "profile")];
    appliedProfile = applied;
    var config = shell && shell.shellConfig ? shell.shellConfig : null;
    var idle = config && config.idle && typeof config.idle === "object" ? config.idle : {};
    var idleService = idleServiceNow();
    appliedIdle = {
      // Raw numbers, not normalizeDelay: the never sentinel sits above the
      // range user settings are clamped to.
      screensaver: Number(idle.screensaver),
      lock: Number(idle.lock),
      stayAwake: idleService ? !!idleService.stayAwake : false
    };
    settled = true;
    resolveServices();
    refreshCharge();
    syncLidInhibit();
    log("settled", "source=" + source + " battery=" + batteryPresent + " lid=" + lidPresent + " kbd=" + kbdAvailable + " profile=" + strategy.profile + " idle=" + JSON.stringify(appliedIdle));
  }

  Timer {
    id: settleTimer
    interval: 2000
    repeat: false
    onTriggered: root.settle()
  }

  // ------------------------------------------------------------------- sync

  property bool syncScheduled: false

  function scheduleSync() {
    if (!settled || syncScheduled)
      return;
    syncScheduled = true;
    Qt.callLater(root.syncAll);
  }

  function syncAll() {
    syncScheduled = false;
    if (!settled)
      return;
    // An entry that is gone means the plugin was disabled: write nothing.
    if (!shell || !Model.findEntry(shell.shellConfig, pluginId))
      return;
    syncProfiles();
    syncIdle();
    syncKbd();
  }

  // --------------------------------------------------------------- processes

  // One action process at a time; later commands wait their turn so two
  // writers never race on the same state file.
  function enqueue(label, command) {
    var next = queue.slice();
    next.push({
      label: label,
      command: command
    });
    queue = next;
    runNext();
  }

  function runNext() {
    if (actionProc.running || queue.length === 0)
      return;
    var item = queue[0];
    queue = queue.slice(1);
    log("process-start", item.label);
    actionProc.command = item.command;
    actionProc.running = true;
  }

  Process {
    id: actionProc
    onExited: function (exitCode) {
      if (exitCode !== 0)
        root.log("process-failed", "exit " + exitCode);
      root.runNext();
      root.refreshProfiles();
    }
  }

  // ---------------------------------------------------------------- profiles

  function refreshProfiles() {
    if (!profilesProc.running)
      profilesProc.running = true;
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseProfiles(text);
        // Keep the last known list across a transient empty read.
        if (parsed.profiles.length === 0)
          return;
        root.profiles = parsed.profiles;
        root.activeProfile = parsed.active;
      }
    }
  }

  function setProfile(src, profile) {
    var key = Model.sourceKey(src, "profile");
    var value = Model.normalizeProfile(profile, settings[key], profiles);
    var patch = {};
    patch[key] = value;
    saveSettings(patch);
  }

  // Applies the configured profile for `src` when it is the current source, or
  // only persists it otherwise. omarchy-powerprofiles-set always applies what it
  // persists, so the other source's choice is written straight into the same
  // state file the script reads, in the same one-line format.
  function syncProfile(src) {
    var profile = settings[Model.sourceKey(src, "profile")];
    if (appliedProfile[src] === profile)
      return;
    var applied = {};
    for (var k in appliedProfile)
      applied[k] = appliedProfile[k];
    applied[src] = profile;
    appliedProfile = applied;
    if (src === source) {
      enqueue("profile " + src + " " + profile, ["omarchy-powerprofiles-set", src, profile]);
    } else {
      enqueue("profile-persist " + src + " " + profile, ["bash", "-c", 'mkdir -p "$1" && printf "%s\\n" "$3" >"$1/$2"', "_", powerProfilesStateDir, src, profile]);
    }
  }

  // Only the sources this machine can be on: a desktop never persists a
  // battery profile it cannot switch to.
  function syncProfiles() {
    for (var i = 0; i < hardware.sources.length; i++)
      syncProfile(hardware.sources[i]);
  }

  // ------------------------------------------------------------------- sleep

  // The first-party lock service may mount after us, so it is looked up
  // until found rather than bound once.
  property var lockService: null
  readonly property bool locked: lockService ? !!lockService.locked : false
  readonly property bool sleepArmed: settled && locked && strategy.sleep > 0

  function resolveServices() {
    if (!lockService && shell && typeof shell.serviceFor === "function")
      lockService = shell.serviceFor("omarchy.lock");
    if (!lockService)
      serviceLookupTimer.start();
  }

  Timer {
    id: serviceLookupTimer
    interval: 5000
    repeat: false
    onTriggered: root.resolveServices()
  }

  // Armed only while the session is locked: the delay counts from the lock
  // and from the last input on the lock screen, and idle inhibitors (a
  // download, a video) hold it off like they hold off the lock itself.
  IdleMonitor {
    id: sleepMonitor
    enabled: root.sleepArmed
    timeout: Math.max(1, root.strategy.sleep)
    respectInhibitors: true
    onIsIdleChanged: {
      if (isIdle && enabled)
        root.suspend("sleep-after-lock " + root.strategy.sleep + "s");
    }
  }

  onLockedChanged: log("lock", locked ? "locked" : "unlocked")
  onSleepArmedChanged: log("sleep", sleepArmed ? "armed " + strategy.sleep + "s" : "disarmed")

  function suspend(reason) {
    if (sleepProc.running)
      return;
    log("suspend", reason);
    sleepProc.command = ["systemctl", "suspend"];
    sleepProc.running = true;
  }

  Process {
    id: sleepProc
    onExited: function (exitCode) {
      if (exitCode !== 0)
        root.log("suspend-failed", "exit " + exitCode);
    }
  }

  // --------------------------------------------------------------- clamshell

  // Quickshell.screens lists the enabled outputs; with the lid closed the
  // internal panel is gone from it, so the external one is what remains.
  readonly property var screenNames: {
    var out = [];
    var screens = Quickshell.screens || [];
    for (var i = 0; i < screens.length; i++)
      out.push(screens[i].name);
    return out;
  }
  readonly property bool externalScreen: Model.hasExternalScreen(screenNames)
  readonly property var lidBehavior: Model.lidBehavior(settings.clamshell, externalScreen, lidPresent)

  // One probe at startup: a machine gains or loses a lid only with a reboot.
  Process {
    id: lidProbeProc
    command: ["bash", "-c", "ls /proc/acpi/button/lid 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.lidPresent = Model.parseLidProbe(text);
        root.lidProbed = true;
        root.log("lid-probe", root.lidPresent ? "lid switch found" : "no lid switch");
      }
    }
  }
  // Held by a child process, so it dies with the shell and can never strand
  // the laptop awake in a bag.
  readonly property bool lidInhibitWanted: settled && lidBehavior.inhibit
  readonly property bool lidInhibited: lidInhibitProc.running

  Process {
    id: lidInhibitProc
    command: ["systemd-inhibit", "--what=handle-lid-switch", "--who=gdeyoung.powercore", "--why=Clamshell: keep running with the lid closed", "--mode=block", "sleep", "infinity"]
    onExited: function (exitCode) {
      root.log("lid-inhibit", "released (exit " + exitCode + ")");
    }
  }

  function syncLidInhibit() {
    if (lidInhibitWanted && !lidInhibitProc.running) {
      log("lid-inhibit", "held (external screen, clamshell on)");
      lidInhibitProc.running = true;
    } else if (!lidInhibitWanted && lidInhibitProc.running) {
      lidInhibitProc.running = false;
    }
  }

  onLidInhibitWantedChanged: syncLidInhibit()

  function setClamshell(enabled) {
    saveSettings({
      clamshell: !!enabled
    });
  }

  // ------------------------------------------------------ keyboard backlight

  // One probe at startup: the LED directory and its max_brightness, plus the
  // current level so the panel can show live state. brightnessctl drives the
  // LED without root (logind SetBrightness fallback), so writes go through it.
  Process {
    id: kbdProbeProc
    command: ["sh", "-c",
      "led=$(for d in /sys/class/leds/*kbd_backlight*; do [ -r \"$d/brightness\" ] && { printf '%s' \"$d\"; break; }; done); " +
      "if [ -n \"$led\" ]; then " +
      "printf '%s\\n%s\\n%s\\n' \"$(basename \"$led\")\" \"$(cat \"$led/max_brightness\" 2>/dev/null || echo 0)\" \"$(cat \"$led/brightness\" 2>/dev/null || echo 0)\"; " +
      "fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text).split("\n");
        root.kbdLedName = String(lines[0] || "").trim();
        root.kbdLedMax = parseInt(lines[1], 10) || 0;
        var raw = parseInt(lines[2], 10) || 0;
        root.kbdProbed = true;
        if (root.kbdAvailable) {
          root.appliedKbdPercent = Model.rawToPercent(raw, root.kbdLedMax);
          root.log("kbd-probe", root.kbdLedName + " max " + root.kbdLedMax + " now " + raw);
          root.refreshKbd();
        } else {
          root.log("kbd-probe", "no kbd_backlight LED; backlight section stands down");
        }
      }
    }
  }

  // Single-writer LED discipline: percent is written only through setKbd.
  // `force` re-asserts even when the value has not changed (resume drift).
  function setKbd(percent, force) {
    if (!kbdAvailable)
      return;
    var next = Model.clampPercent(percent);
    if (!force && next === appliedKbdPercent)
      return;
    appliedKbdPercent = next;
    log("kbd", String(next) + "%");
    var raw = String(Model.percentToRaw(next, kbdLedMax));
    if (kbdWriteProc.running) {
      _pendingKbdRaw = raw;
      return;
    }
    kbdWriteProc.command = ["brightnessctl", "-d", kbdLedName, "-q", "set", raw];
    kbdWriteProc.running = true;
  }

  property string _pendingKbdRaw: ""

  Process {
    id: kbdWriteProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running)
        return;
      if (root._pendingKbdRaw !== "") {
        var queued = root._pendingKbdRaw;
        root._pendingKbdRaw = "";
        kbdWriteProc.command = ["brightnessctl", "-d", root.kbdLedName, "-q", "set", queued];
        kbdWriteProc.running = true;
      }
    }
  }

  // Manual override from the panel or the bar: applies now and persists as
  // the strategy for the CURRENT source, so the next plug/unplug returns to
  // the other source's own level.
  function setKbdManual(percent) {
    setKbd(percent, false);
    var patch = {};
    patch[Model.sourceKey(source, "kbdBacklight")] = Model.clampPercent(percent);
    saveSettings(patch);
  }

  // Re-assert the strategy level only when the hardware drifted from what we
  // last asked for (resume from sleep, an Fn key). Never fights a manual
  // change because a manual change goes through setKbdManual, which updates
  // appliedKbdPercent and the strategy together.
  function syncKbd() {
    if (!settled || !kbdAvailable)
      return;
    var want = strategy.kbdBacklight;
    if (want !== appliedKbdPercent)
      setKbd(want, false);
  }

  function refreshKbd() {
    if (kbdAvailable && !kbdReadProc.running)
      kbdReadProc.running = true;
  }

  Process {
    id: kbdReadProc
    command: ["brightnessctl", "-d", root.kbdLedName, "-m", "info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // brightnessctl -m prints: device,class,current,max,percent,percent-str
        var parts = String(text).split(",");
        if (parts.length < 5)
          return;
        var raw = parseInt(parts[2], 10);
        var max = parseInt(parts[3], 10);
        if (!isFinite(raw) || !isFinite(max) || max <= 0)
          return;
        root.kbdLedMax = max;
        var nowPercent = Model.rawToPercent(raw, max);
        // Drift (resume, Fn key): re-assert what the strategy wants. This
        // slow poll is also the resume path: Omarchy's system-sleep hook
        // zeroes the LED, and the next tick puts it back.
        if (root.settled && nowPercent !== root.appliedKbdPercent)
          root.setKbd(root.appliedKbdPercent, true);
      }
    }
  }

  // Slow drift poll: catches resume-from-sleep zeroing and Fn-key changes
  // without spawning a process more often than a widget needs to care.
  Timer {
    id: kbdPollTimer
    interval: 5000
    running: root.kbdAvailable
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refreshKbd()
  }

  function setKbdSource(src, percent) {
    var key = Model.sourceKey(src, "kbdBacklight");
    var patch = {};
    patch[key] = Model.normalizeKbdPercent(percent, settings[key]);
    saveSettings(patch);
    if (src === source)
      setKbd(patch[key], false);
  }

  // --------------------------------------------------------------- power draw

  // Live draw sampling. One short-lived process per tick (the energy-meter
  // daemon pattern, scoped down to a widget poll: no daemon, no history DB,
  // a fresh sampler every interval keeps the shell process unprivileged and
  // the script stateless).
  property var drawSample: null
  readonly property real drawWatts: drawSample ? drawSample.watts : 0
  readonly property string drawMethod: drawSample ? drawSample.mode : ""

  function refreshDraw() {
    if (!drawProc.running)
      drawProc.running = true;
  }

  Process {
    id: drawProc
    command: [root.pluginDir + "/powerdraw.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseDrawSample(text);
        if (next)
          root.drawSample = next;
        else if (root.drawSample && String(text).trim() === "none")
          root.drawSample = null;
      }
    }
  }

  Timer {
    id: drawTimer
    interval: Math.max(2000, root.settings.wattsRefreshSec * 1000)
    running: root.settled
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refreshDraw()
  }

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("powerdraw.sh"));
    var path = decodeURIComponent(url.indexOf("file://") === 0 ? url.substring(7) : url);
    var cut = path.lastIndexOf("/");
    return cut === -1 ? "." : path.slice(0, cut);
  }

  // ------------------------------------------------------------ charge limit

  // Quickshell's UPower module does not expose the charge threshold
  // properties, so they are read over D-Bus. UPower's EnableChargeThreshold
  // is allowed for the active session by polkit, so no prompt and no root.
  // On ASUS firmware the thresholds themselves (75-80) are fixed by the BIOS;
  // there is no writable numeric API, so the toggle is the whole control.
  property var chargeState: ({
      supported: false,
      settings: 0,
      enabled: false,
      start: 0,
      end: 0
    })
  readonly property var chargeCapability: Model.chargeCapability(chargeState)
  readonly property bool chargeLimitEnabled: !!chargeState.enabled
  property bool chargeBusy: false

  readonly property string chargeProbeScript: ['dev=$(upower -e 2>/dev/null | grep -m1 BAT) || exit 0', '[ -n "$dev" ] || exit 0', 'get() { busctl get-property org.freedesktop.UPower "$dev" org.freedesktop.UPower.Device "$1" 2>/dev/null | cut -d" " -f2; }', 'printf "supported\\t%s\\n" "$(get ChargeThresholdSupported)"', 'printf "settings\\t%s\\n" "$(get ChargeThresholdSettingsSupported)"', 'printf "enabled\\t%s\\n" "$(get ChargeThresholdEnabled)"', 'printf "start\\t%s\\n" "$(get ChargeStartThreshold)"', 'printf "end\\t%s\\n" "$(get ChargeEndThreshold)"'].join("\n")

  function refreshCharge() {
    if (!hardware.chargeControl) {
      chargeState = Model.parseChargeState("");
      return;
    }
    if (!chargeProc.running)
      chargeProc.running = true;
  }

  Process {
    id: chargeProc
    command: ["bash", "-c", root.chargeProbeScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseChargeState(text);
        if (JSON.stringify(next) !== JSON.stringify(root.chargeState))
          root.chargeState = next;
      }
    }
  }

  function setChargeLimit(enabled) {
    if (!chargeCapability.available || chargeSetProc.running)
      return;
    var value = !!enabled;
    chargeBusy = true;
    log("charge-limit", value ? "enable" : "disable");
    chargeSetProc.command = ["bash", "-c", 'dev=$(upower -e 2>/dev/null | grep -m1 BAT) && busctl call org.freedesktop.UPower "$dev" org.freedesktop.UPower.Device EnableChargeThreshold b "$1"', "_", value ? "true" : "false"];
    chargeSetProc.running = true;
  }

  Process {
    id: chargeSetProc
    onExited: function (exitCode) {
      root.chargeBusy = false;
      if (exitCode !== 0)
        root.log("charge-limit-failed", "exit " + exitCode);
      root.refreshCharge();
    }
  }

  // -------------------------------------------------------------------- idle

  // Looked up at call time: the first-party idle service may mount after us.
  function idleServiceNow() {
    return shell && typeof shell.serviceFor === "function" ? shell.serviceFor("omarchy.idle") : null;
  }

  // Writes the current strategy's timings into shell.json, which the
  // first-party idle service reads live. The stay-awake handling is
  // asymmetric on purpose: when the strategy needs the cycle off (both
  // timings never), the plugin switches it off and remembers; when the
  // strategy has something to fire again, it switches back on only what it
  // had switched off. A stay-awake the USER toggled from the indicator is
  // never stomped — it outranks the strategy until they clear it.
  property bool forcedStayAwake: false

  function syncIdle() {
    var target = Model.idleConfigFor(strategy);
    if (Model.sameIdleConfig(appliedIdle, target))
      return;
    appliedIdle = target;
    if (shell && typeof shell.mutateShellConfig === "function") {
      shell.mutateShellConfig(function (config) {
        var idle = config.idle && typeof config.idle === "object" ? config.idle : {};
        idle.screensaver = target.screensaver;
        idle.lock = target.lock;
        config.idle = idle;
      });
    } else {
      log("idle-not-persisted", "shell has no mutateShellConfig");
    }
    var idleService = idleServiceNow();
    if (target.stayAwake && !forcedStayAwake) {
      forcedStayAwake = true;
      if (idleService && typeof idleService.setIdleEnabled === "function")
        idleService.setIdleEnabled(false);
      else
        log("idle-service-missing", "stay-awake not applied");
    } else if (!target.stayAwake && forcedStayAwake) {
      forcedStayAwake = false;
      if (idleService && typeof idleService.setIdleEnabled === "function")
        idleService.setIdleEnabled(true);
    }
    log("idle", source + " screensaver=" + target.screensaver + " lock=" + target.lock + " stayAwake=" + target.stayAwake);
  }

  function setDelay(src, field, seconds) {
    if (["screensaver", "lock", "sleep"].indexOf(field) === -1)
      return;
    var key = Model.sourceKey(src, field);
    var patch = {};
    patch[key] = Model.normalizeDelay(seconds, settings[key]);
    saveSettings(patch);
  }

  // ------------------------------------------------------------------ status

  function statusJson() {
    return JSON.stringify({
      source: root.source,
      batteryPresent: root.batteryPresent,
      lidPresent: root.lidPresent,
      lidProbed: root.lidProbed,
      kbd: {
        available: root.kbdAvailable,
        led: root.kbdLedName,
        max: root.kbdLedMax,
        percent: root.appliedKbdPercent
      },
      hardware: root.hardware,
      settled: root.settled,
      profiles: root.profiles,
      activeProfile: root.activeProfile,
      settings: root.settings,
      strategy: root.strategy,
      appliedProfile: root.appliedProfile,
      appliedIdle: root.appliedIdle,
      externalScreen: root.externalScreen,
      screens: root.screenNames,
      lidInhibited: root.lidInhibited,
      lidBehavior: root.lidBehavior,
      charge: root.chargeState,
      chargeCapability: root.chargeCapability,
      draw: {
        sample: root.drawSample,
        method: root.drawMethod,
        watts: root.drawWatts
      },
      lockService: !!root.lockService,
      locked: root.locked,
      sleepArmed: root.sleepArmed,
      queue: root.queue.length,
      lastEvent: root.lastEvent,
      lastEventAt: root.lastEventAt
    });
  }

  onSourceChanged: {
    log("source", source);
    refreshCharge();
    // The first-party battery service re-applies the persisted profile on a
    // source switch; ours makes sure the persisted values and idle timings
    // match this source's strategy.
    scheduleSync();
    refreshDraw();
  }

  onShellChanged: readSettings()

  // A battery appearing or going away (rare, hot-swap or a stale UPower read
  // at boot) changes which sources exist and whether charge control is probed.
  onBatteryPresentChanged: {
    log("battery", batteryPresent ? "present" : "absent");
    refreshCharge();
    scheduleSync();
  }

  Component.onDestruction: {
    if (lidInhibitProc.running)
      lidInhibitProc.running = false;
  }

  Component.onCompleted: {
    readSettings();
    refreshProfiles();
    lidProbeProc.running = true;
    kbdProbeProc.running = true;
    settleTimer.start();
    log("service-ready", "source=" + source);
  }
}
