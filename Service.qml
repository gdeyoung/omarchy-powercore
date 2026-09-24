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
    var entry = Model.entryForShell(shell, pluginId);
    var next = entry || ({});
    if (JSON.stringify(next) === JSON.stringify(rawSettings))
      return;
    rawSettings = next;
    scheduleSync();
  }

  // Settings writes are serialized and confirmed: each updateEntryInline is
  // merged onto the last CONFIRMED file content (rawSettings, updated by the
  // shell.json watch), and the next queued patch waits for that
  // confirmation. The pushed barConfig can lag a burst of writes; merging
  // from it mid-burst silently resurrects older sibling values.
  property var pendingSettingPatches: []
  property bool settingsWriteBusy: false

  function saveSettings(patch) {
    pendingSettingPatches = pendingSettingPatches.concat([patch]);
    drainSettings();
  }

  function drainSettings() {
    if (settingsWriteBusy || pendingSettingPatches.length === 0)
      return;
    settingsWriteBusy = true;
    var merged = {};
    for (var k in rawSettings)
      merged[k] = rawSettings[k];
    for (var p = 0; p < pendingSettingPatches.length; p++) {
      var patch = pendingSettingPatches[p];
      for (var key in patch) {
        if (patch[key] === undefined)
          delete merged[key];
        else
          merged[key] = patch[key];
      }
    }
    pendingSettingPatches = [];
    settingsBusyTimer.restart();
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(pluginId, merged);
    else {
      settingsWriteBusy = false;
      settingsBusyTimer.stop();
      log("settings-not-persisted", "shell has no updateEntryInline");
    }
  }

  // No-op writes (same content) never change the file, so the confirmation
  // watch would never fire; this clears the busy flag instead.
  Timer {
    id: settingsBusyTimer
    interval: 3000
    repeat: false
    onTriggered: {
      root.settingsWriteBusy = false;
      root.drainSettings();
    }
  }

  // The scoped plugin API exposes no shellConfig-change signal; config
  // pushes arrive as barConfig reassignments. Both are covered.
  Connections {
    target: root.shell
    function onBarConfigChanged() {
      root.readSettings();
    }
    function onShellConfigChanged() {
      root.readSettings();
    }
  }

  // Remember what is already in effect, then start syncing on changes.
  function settle() {
    if (settled)
      return;
    readSettings();
    syncAppliedIdleFromConfig();
    var applied = {};
    for (var i = 0; i < hardware.sources.length; i++)
      applied[hardware.sources[i]] = settings[Model.sourceKey(hardware.sources[i], "profile")];
    // The boot autostart applies a generic profile (performance on AC), not
    // this plugin's persisted choice, so for the CURRENT source the kernel
    // word is the truth — syncing against the settings value would skip the
    // write and leave the wrong profile active until the next source switch.
    if (activeProfile !== "")
      applied[source] = activeProfile;
    appliedProfile = applied;
    settled = true;
    refreshCharge();
    syncLidInhibit();
    // The persisted strategy must reach the kernel even when nothing
    // changed since last boot (the boot autostart applies a generic
    // default, not this plugin's per-source choice).
    scheduleSync();
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
    if (!shell || !Model.entryForShell(shell, pluginId))
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

  // The scoped plugin API cannot reach the first-party lock service
  // (serviceFor is own-id only), so locked state comes from its IPC verb.
  // Polled only while a sleep-after-lock delay is configured and the
  // session is settled; ~10s of detection latency against a minutes-long
  // sleep delay is noise.
  property bool locked: false
  readonly property bool sleepArmed: settled && locked && strategy.sleep > 0

  Timer {
    id: lockPollTimer
    interval: 10000
    running: root.settled && root.strategy.sleep > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!lockPollProc.running) lockPollProc.running = true
  }

  Process {
    id: lockPollProc
    command: ["bash", "-c", "omarchy-shell lock isLocked 2>/dev/null || printf false"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.locked = String(text).trim() === "true"
    }
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
        // brightnessctl -m prints: device,class,current,percent-str,max
        var parts = String(text).split(",");
        if (parts.length < 5)
          return;
        var raw = parseInt(parts[2], 10);
        var max = parseInt(parts[4], 10);
        if (!isFinite(raw) || !isFinite(max) || max <= 0)
          return;
        root.kbdLedMax = max;
        // Drift (resume, Fn key) is a RAW-step difference: percent is a
        // display mapping that loses resolution on coarse LEDs (40% and 33%
        // are both raw step 1 on a max-3 LED), so comparing percents would
        // re-assert forever. This slow poll is also the resume path:
        // Omarchy's system-sleep hook zeroes the LED, and the next tick puts
        // it back.
        var appliedRaw = Model.percentToRaw(root.appliedKbdPercent, max);
        if (root.settled && raw !== appliedRaw)
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

  // The Omarchy 4.x scoped plugin API gives a third-party service no
  // shellConfig and no cross-service serviceFor; idle is reached through the
  // sanctioned first-party proxy (bar-capable plugins get omarchy.idle) with
  // the documented CLI as fallback, and the idle block of shell.json is
  // read/written through the file itself (the shell hot-reloads it).
  function idleProxy() {
    return shell && typeof shell.firstPartyServiceFor === "function"
      ? shell.firstPartyServiceFor("omarchy.idle") : null;
  }

  // Live stay-awake truth from the same state file the idle service and
  // `omarchy toggle idle` use — works whichever path last wrote it. The
  // file can be absent (stay-awake off) or created empty (on), so presence
  // is probed with a process and the indicator directory is watched, the
  // same pattern the first-party idle service uses.
  readonly property string stayAwakeStatePath: home + "/.local/state/omarchy/indicators/stay-awake"
  readonly property string indicatorsDir: home + "/.local/state/omarchy/indicators"

  property bool userStayAwake: false

  function setStayAwake(value, persist, reason) {
    var enabled = !!value;
    if (persist) {
      var fileArg = enabled ? "stay-awake" : "allow-idle";
      enqueue("stay-awake " + (enabled ? "on" : "off") + (reason ? " " + reason : ""),
              ["omarchy-toggle-idle", fileArg]);
    }
    if (userStayAwake !== enabled)
      userStayAwake = enabled;
  }

  Process {
    id: stayAwakeProbe
    command: ["bash", "-c",
      'mkdir -p "$1" 2>/dev/null; [[ -f "$1/stay-awake" ]] && echo yes || echo no',
      "_", root.indicatorsDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.userStayAwake = String(text).trim() === "yes"
    }
    onExited: stayAwakeDirWatch.reload()
  }

  FileView {
    id: stayAwakeDirWatch
    path: root.indicatorsDir
    watchChanges: true
    printErrors: false
    onFileChanged: {
      stayAwakeDirWatch.reload();
      if (!stayAwakeProbe.running)
        stayAwakeProbe.running = true;
    }
  }

  FileView {
    id: shellJsonWatch
    path: home + "/.config/omarchy/shell.json"
    preload: true
    watchChanges: true
    printErrors: false
    onFileChanged: shellJsonWatch.reload()
    onLoaded: root.syncFromShellJsonFile()
    onLoadFailed: root.syncAppliedIdleFromConfig()
  }

  // shell.json is the ground truth for both the idle block and this plugin's
  // entry settings. The barConfig push is the fast path; the file watch is
  // the convergence path (covers lost pushes and external edits alike).
  function syncFromShellJsonFile() {
    // A file change is the write confirmation: the shell has persisted, so
    // the next queued settings patch may merge onto fresh content.
    settingsWriteBusy = false;
    settingsBusyTimer.stop();
    drainSettings();
    var parsed = null;
    try {
      parsed = JSON.parse(String(shellJsonWatch.text() || ""));
    } catch (error) {
      parsed = null;
    }
    if (parsed && typeof parsed === "object") {
      var entry = Model.findEntry(parsed, pluginId);
      if (entry && JSON.stringify(entry) !== JSON.stringify(rawSettings)) {
        rawSettings = entry;
        scheduleSync();
      }
    }
    syncAppliedIdleFromConfig();
  }

  // External idle edits (user, another tool) must not be re-applied over:
  // appliedIdle tracks what shell.json actually says now.
  function syncAppliedIdleFromConfig() {
    var parsed = Model.idleFromShellJsonText(shellJsonWatch.text());
    if (!parsed)
      return;
    var next = {
      screensaver: isFinite(parsed.screensaver) ? parsed.screensaver : null,
      lock: isFinite(parsed.lock) ? parsed.lock : null,
      stayAwake: userStayAwake
    };
    if (!Model.sameIdleConfig(appliedIdle, next))
      appliedIdle = next;
  }

  // Idle truth for the panel/status: the live proxy when present, the state
  // file otherwise.
  readonly property var idleInfo: {
    var proxy = idleProxy();
    if (proxy)
      return { enabled: proxy.enabled, stayAwake: proxy.stayAwake, live: true };
    return { enabled: !userStayAwake, stayAwake: userStayAwake, live: false };
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
    var idleService = idleProxy();
    var currentStayAwake = idleService ? !!idleService.stayAwake : userStayAwake;
    // Timings only: stayAwake in appliedIdle is the observed user state, not
    // something this strategy wrote. Nulls mean "not yet known" — the first
    // sync after settle always runs.
    if (appliedIdle && appliedIdle.screensaver !== null
        && appliedIdle.screensaver === target.screensaver
        && appliedIdle.lock === target.lock)
      return;
    appliedIdle = {
      screensaver: target.screensaver,
      lock: target.lock,
      stayAwake: currentStayAwake
    };
    enqueue("idle " + source + " screensaver=" + target.screensaver + " lock=" + target.lock,
            [pluginDir + "/shelljson-idle.sh", String(target.screensaver), String(target.lock)]);
    if (target.stayAwake && !forcedStayAwake && !currentStayAwake) {
      forcedStayAwake = true;
      setStayAwake(true, true, "strategy");
    } else if (!target.stayAwake && forcedStayAwake) {
      forcedStayAwake = false;
      if (currentStayAwake)
        setStayAwake(false, true, "strategy-restore");
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
      idle: root.idleInfo,
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
      lockPollActive: lockPollTimer.running,
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
    stayAwakeProbe.running = true;
    settleTimer.start();
    log("service-ready", "source=" + source);
  }
}
