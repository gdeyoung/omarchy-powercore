import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The gdeyoung.powercore popup. Reads state from the service, calls its
// functions, and never computes policy or touches the system itself.
Panel {
  id: root
  moduleName: "gdeyoung.powercore"
  ipcTarget: "gdeyoung.powercore"
  // The single IpcHandler for this target lives here so it can expose status
  // from the service next to open/close.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor("gdeyoung.powercore") : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var device: UPower.displayDevice
  readonly property bool batteryPresent: !!(device && device.isPresent)
  readonly property string source: UPower.onBattery ? "battery" : "ac"
  readonly property int percentage: batteryPresent ? Math.round(Number(device.percentage || 0) * 100) : -1
  readonly property var upowerStates: ({
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    })
  readonly property bool onBattery: UPower.onBattery
  readonly property real batteryFraction: Model.batteryFraction(device)
  readonly property bool chargeThresholdActive: Model.chargeThresholdActive(device, onBattery, upowerStates)
  readonly property bool fullyCharged: batteryPresent && device.state === UPowerDeviceState.FullyCharged && !chargeThresholdActive
  readonly property bool batteryFull: fullyCharged || (!onBattery && batteryFraction >= 1)
  readonly property bool charging: batteryPresent && !onBattery && !batteryFull && !chargeThresholdActive
  readonly property string batteryIcon: Model.batteryIcon(device, onBattery, upowerStates)
  readonly property string modeLabel: Model.heroFallbackStatus(device, onBattery, upowerStates, activeProfile)

  // What this machine offers; the service decides once, the panel hides the
  // rest. Before the service is up, assume the least: no battery, no lid, no LED.
  readonly property var hardware: service ? service.hardware : Model.hardware(batteryPresent, false, false)
  readonly property var sources: hardware.sources
  readonly property string activeProfile: service ? service.activeProfile : ""

  // Stats from omarchy-battery-status, refreshed while the panel is open.
  property var batteryInfo: ({})
  property int phraseIndex: 0
  readonly property var activePhrases: fullyCharged ? [] : (charging ? Model.CHARGING_PHRASES : (onBattery && batteryPresent ? Model.ON_BATTERY_PHRASES : []))
  readonly property bool rotatingPhrases: activePhrases.length > 0
  readonly property string heroStatusText: fullyCharged ? "Fully charged" : (rotatingPhrases ? activePhrases[phraseIndex % activePhrases.length] : modeLabel)
  readonly property string heroTitle: Model.heroTitle(batteryPresent)
  readonly property string chargeLimitText: Model.chargeLimitLabel(service ? service.chargeState : null, batteryInfo.threshold || "")

  // Live draw from the service sampler.
  readonly property real drawWatts: service && service.drawSample ? service.drawSample.watts : 0
  readonly property string drawMethod: service && service.drawSample ? service.drawSample.mode : ""

  function updateBatteryInfo(raw) {
    var next = Model.parseKeyValue(raw);
    // Keep last known good data across a transient empty read (plug events).
    if (Object.keys(next).length === 0)
      return;
    batteryInfo = next;
  }

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateBatteryInfo(text)
    }
  }

  function refreshBattery() {
    if (batteryPresent && !batteryProc.running)
      batteryProc.running = true;
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refreshBattery()
  }

  Timer {
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus
      property: "opacity"
      to: 0.0
      duration: 180
      easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length;
        if (n > 0)
          root.phraseIndex = (root.phraseIndex + 1) % n;
      }
    }
    PropertyAnimation {
      target: heroStatus
      property: "opacity"
      to: 1.0
      duration: 260
      easing.type: Easing.InQuad
    }
  }

  onRotatingPhrasesChanged: {
    if (!rotatingPhrases) {
      phraseSwap.stop();
      heroStatus.opacity = 1.0;
    }
  }
  readonly property var profiles: service ? service.profiles : []
  readonly property var profileOptions: Model.profileOptions(profiles)
  readonly property var settingsView: Model.normalizeSettings(root.settings, profiles)

  readonly property var chargeCapability: service ? service.chargeCapability : Model.chargeCapability(null)
  readonly property bool chargeLimitEnabled: service ? service.chargeLimitEnabled : false
  readonly property bool chargeBusy: service ? service.chargeBusy : false
  readonly property bool externalScreen: service ? service.externalScreen : false
  readonly property var lidBehavior: service ? service.lidBehavior : Model.lidBehavior(false, false)

  // Lid close behavior (vendored daferia.lid-sleep mechanism): APPLIED state
  // from the service (systemd drop-ins via lidsleep.sh), DESIRED from
  // settings. They diverge until the user runs the elevated apply.
  readonly property var lidState: service ? service.lidState : null
  readonly property bool lidPending: service ? service.lidPendingNow : false
  readonly property bool lidHibernationReady: !lidState || lidState.hibernationReady
  readonly property bool lidHasHistory: !!lidState && !!lidState.history && lidState.history.length > 0
  readonly property var lidDrain: Model.drainSummary(lidState && lidState.history ? lidState.history : [])
  readonly property string lidAppliedKey: lidState ? lidState.mode + ":" + lidState.delayMin : ""
  property string lidHeroSentence: ""
  onLidAppliedKeyChanged: lidSwap.restart()
  Component.onCompleted: {
    lidHeroSentence = lidState ? Model.lidModeSummary(lidState.mode, lidState.delayMin) : "";
  }

  // Hero sentence swap on applied-mode change: fade out, swap, fade in.
  SequentialAnimation {
    id: lidSwap
    PropertyAnimation {
      target: lidHeroText
      property: "opacity"
      to: 0.0
      duration: 180
      easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        root.lidHeroSentence = root.lidState ? Model.lidModeSummary(root.lidState.mode, root.lidState.delayMin) : "";
      }
    }
    PropertyAnimation {
      target: lidHeroText
      property: "opacity"
      to: 1.0
      duration: 260
      easing.type: Easing.InQuad
    }
  }

  // Keyboard backlight live state from the service.
  readonly property bool kbdAvailable: service ? service.kbdAvailable : false
  readonly property int kbdPercent: service && service.appliedKbdPercent !== undefined ? service.appliedKbdPercent : 0
  readonly property int kbdMax: service ? service.kbdLedMax : 0
  readonly property var kbdLedName: service ? service.kbdLedName : ""

  // Keyboard cursor over a grid. Row 0 is the protection toggle (when shown),
  // then the clamshell toggle; then the lid section rows on a machine with a
  // lid: kind 0 = six mode buttons (one logical row across two visual rows),
  // kind 1 = delay dropdown + test button, kind 2 = apply (only while a
  // change is pending). Then each source owns three rows: profile buttons,
  // delay dropdowns, kbd dropdown. -1 means the cursor is parked.
  readonly property int rowsPerSource: 3
  readonly property int lidRows: hardware.clamshell ? (lidPending ? 3 : 2) : 0
  readonly property int sourceBase: headRows + lidRows
  // Head controls in order: charge toggle when available, then clamshell on a
  // machine with a lid. Both may be absent (a desktop): the head is then empty.
  readonly property var headKeys: {
    var keys = [];
    if (chargeCapability.available)
      keys.push("charge");
    if (hardware.clamshell)
      keys.push("clamshell");
    return keys;
  }
  readonly property bool chargeNoteVisible: hardware.battery && !chargeCapability.available
  readonly property bool headVisible: headKeys.length > 0 || chargeNoteVisible
  readonly property int headRows: headKeys.length
  property int cursorRow: -1
  property int cursorIndex: 0
  readonly property bool cursorActive: cursorRow >= 0
  readonly property string cursorHead: cursorActive && cursorRow < headRows ? headKeys[cursorRow] : ""
  readonly property bool cursorOnCharge: cursorHead === "charge"
  readonly property bool cursorOnClamshell: cursorHead === "clamshell"
  readonly property bool cursorOnLid: cursorActive && lidRows > 0 && cursorRow >= headRows && cursorRow < sourceBase
  readonly property int cursorLidKind: cursorOnLid ? cursorRow - headRows : -1
  readonly property int cursorSource: cursorActive && !cursorOnCharge && !cursorOnLid ? Math.floor((cursorRow - sourceBase) / rowsPerSource) : -1
  readonly property int cursorKind: cursorSource >= 0 ? (cursorRow - sourceBase) % rowsPerSource : -1
  readonly property var delayFields: ["screensaver", "lock", "sleep"]
  property var delayControls: ({})

  function registerDelayControl(sourceIndex, fieldIndex, item) {
    var next = {};
    for (var k in delayControls)
      next[k] = delayControls[k];
    next[sourceIndex + ":" + fieldIndex] = item;
    delayControls = next;
  }

  function rowLength(row) {
    if (row < headRows)
      return 1;
    if (row < sourceBase) {
      var kind = row - headRows;
      if (kind === 0)
        return Model.LID_MODES.length;
      if (kind === 1)
        return 2;
      return 1;
    }
    return (row - sourceBase) % rowsPerSource === 0 ? profileOptions.length : delayFields.length;
  }

  function setChargeLimit(enabled) {
    if (service)
      service.setChargeLimit(enabled);
  }

  function setClamshell(enabled) {
    if (service)
      service.setClamshell(enabled);
  }

  function setLidMode(mode) {
    if (service)
      service.setLidMode(mode);
  }

  function setLidDelay(minutes) {
    if (service)
      service.setLidDelay(minutes);
  }

  function applyLid() {
    if (service)
      service.applyLid();
  }

  function testHibernate() {
    if (service)
      service.testHibernate();
  }

  function lidModeEnabled(value) {
    if ((value === "smart" || value === "hibernate") && !lidHibernationReady)
      return false;
    return true;
  }

  function lidGlyph(mode) {
    var m = Model.normalizeLidMode(mode, "system");
    for (var i = 0; i < Model.LID_MODES.length; i++)
      if (Model.LID_MODES[i].value === m)
        return Model.LID_MODES[i].icon;
    return "";
  }

  function lastSleepLabel() {
    if (!lidDrain || !lidDrain.last)
      return "Last sleep";
    return lidDrain.last.type === "hibernate" ? "Last hibernate" : "Last sleep";
  }

  function lastSleepText() {
    if (!lidDrain || !lidDrain.last)
      return "—";
    var l = lidDrain.last;
    return Model.lidDurationLabel(l.minutes) + " · " + l.from + "%→" + l.to + "%";
  }

  function drainText(type) {
    if (!lidDrain || !lidDrain[type])
      return "—";
    return Model.drainLabel(lidDrain[type].perHour) + " · " + lidDrain[type].count + "×";
  }

  function statusJson() {
    var status = service ? JSON.parse(service.statusJson()) : {
      service: "not loaded"
    };
    status.opened = root.opened;
    status.cursor = {
      row: root.cursorRow,
      index: root.cursorIndex
    };
    return JSON.stringify(status);
  }

  function setProfile(src, value) {
    if (service)
      service.setProfile(src, value);
  }

  function setDelay(src, field, seconds) {
    if (service)
      service.setDelay(src, field, seconds);
  }

  function setKbdSource(src, percent) {
    if (service)
      service.setKbdSource(src, percent);
  }

  function moveCursor(dx, dy) {
    var rows = headRows + lidRows + sources.length * rowsPerSource;
    if (!cursorActive) {
      cursorRow = sourceBase + Math.max(0, sources.indexOf(source)) * rowsPerSource;
      cursorIndex = Math.max(0, profileOptions.map(function (o) {
        return o.value;
      }).indexOf(settingsView[Model.sourceKey(source, "profile")]));
      return;
    }
    if (dy !== 0)
      cursorRow = (cursorRow + (dy > 0 ? 1 : -1) + rows) % rows;
    var len = rowLength(cursorRow);
    if (dx !== 0)
      cursorIndex = (cursorIndex + (dx > 0 ? 1 : -1) + len) % len;
    cursorIndex = Math.min(cursorIndex, len - 1);
  }

  function activateCursor() {
    if (!cursorActive)
      return;
    if (cursorOnCharge) {
      setChargeLimit(!chargeLimitEnabled);
      return;
    }
    if (cursorOnClamshell) {
      if (externalScreen)
        setClamshell(!settingsView.clamshell);
      return;
    }
    if (cursorOnLid) {
      if (cursorLidKind === 0) {
        var opt = Model.LID_MODES[cursorIndex];
        if (opt && lidModeEnabled(opt.value))
          setLidMode(opt.value);
        return;
      }
      if (cursorLidKind === 1) {
        if (cursorIndex === 0) {
          if (settingsView.lidMode === "smart" && lidDelayControl && typeof lidDelayControl.open === "function")
            lidDelayControl.open();
        } else if (lidHibernationReady) {
          testHibernate();
        }
        return;
      }
      applyLid();
      return;
    }
    if (cursorKind === 0) {
      if (cursorIndex < profileOptions.length && cursorSource < sources.length)
        setProfile(sources[cursorSource], profileOptions[cursorIndex].value);
      return;
    }
    var control = delayControls[cursorSource + ":" + cursorIndex];
    if (control && typeof control.open === "function")
      control.open();
  }

  onLidPendingChanged: {
    // The apply row vanishes with the pending state; park the cursor if it
    // was standing there (headRows + 2 can only be the apply row while it
    // existed).
    if (!lidPending && cursorRow === headRows + 2)
      cursorRow = -1;
  }

  IpcHandler {
    target: "gdeyoung.powercore"

    function open(): void {
      root.open();
    }
    function close(): void {
      root.close();
    }
    function show(): void {
      root.open();
    }
    function hide(): void {
      root.close();
    }
    function toggle(): void {
      root.toggle();
    }
    function status(): string {
      return root.statusJson();
    }
    function setProfile(source: string, profile: string): string {
      root.setProfile(source, profile);
      return root.statusJson();
    }
    function setDelay(source: string, field: string, seconds: string): string {
      root.setDelay(source, field, seconds);
      return root.statusJson();
    }
    function setChargeLimit(enabled: string): string {
      root.setChargeLimit(enabled === "true");
      return root.statusJson();
    }
    function setClamshell(enabled: string): string {
      root.setClamshell(enabled === "true");
      return root.statusJson();
    }
    function setKbd(source: string, percent: string): string {
      root.setKbdSource(source, percent);
      return root.statusJson();
    }
    function setLidMode(mode: string): string {
      root.setLidMode(mode);
      return root.statusJson();
    }
    function setLidDelay(minutes: string): string {
      root.setLidDelay(Number(minutes));
      return root.statusJson();
    }
    function applyLid(): string {
      root.applyLid();
      return root.statusJson();
    }
    function refreshLid(): string {
      if (root.service)
        root.service.refreshLidState();
      return root.statusJson();
    }
  }

  onOpenedChanged: {
    cursorRow = -1;
    if (opened) {
      refreshBattery();
      if (service) {
        service.refreshProfiles();
        service.refreshCharge();
        service.refreshDraw();
        service.refreshLidState();
      }
    }
  }

  // While a lid change is pending (password not entered yet), re-read the
  // applied state so the pending strip clears itself the moment the
  // drop-ins land.
  Timer {
    id: lidPollTimer
    interval: 5000
    running: root.opened && root.lidPending
    repeat: true
    onTriggered: if (root.service) root.service.refreshLidState()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root  // widget-owner without close() lets KeyboardPanel.close()
                 // assign open=false statically, severing the open binding
                 // on first dismiss-overlay close (panel wedges until reload)
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        root.moveCursor(dx, dy);
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) {
        root.switchPanel(direction);
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.panelGap

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color {
              ColorAnimation {
                duration: 200
              }
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.spacing.xxxl
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.spacing.xl
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              text: root.heroTitle
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            visible: root.batteryPresent
            textFormat: Text.PlainText
            text: root.batteryPresent ? root.percentage + "%" : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          visible: root.batteryPresent
          width: parent.width
          implicitHeight: Style.spacing.lg

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          }

          Rectangle {
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.foreground
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)
            Behavior on width {
              NumberAnimation {
                duration: 320
                easing.type: Easing.OutCubic
              }
            }
            // Subtle pulse while charging: energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation {
                from: 1.0
                to: 0.55
                duration: 950
                easing.type: Easing.InOutSine
              }
              NumberAnimation {
                from: 0.55
                to: 1.0
                duration: 950
                easing.type: Easing.InOutSine
              }
            }
          }
        }

        // ---------- Stats: battery info + live draw ----------
        Row {
          visible: root.batteryInfo.percentage !== undefined || root.drawWatts > 0
          width: parent.width
          spacing: Style.spacing.huge

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: "Battery size"
              value: root.batteryInfo.size || ""
            }
            InfoPair {
              label: "Charge cycles"
              value: root.batteryInfo.cycles || "—"
            }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.onBattery ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? root.chargeLimitText : (root.batteryFull ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: "Power draw"
              value: root.drawWatts > 0 ? Model.formatWatts(root.drawWatts) : "—"
            }
          }
        }

        // ---------- Draw source note ----------
        Text {
          visible: root.drawWatts > 0 && root.drawMethod !== ""
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.Wrap
          text: "Power draw source: " + Model.drawMethodLabel(root.drawMethod)
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator {
          visible: root.headVisible
          foreground: root.foreground
        }

        Toggle {
          visible: root.chargeCapability.available
          width: parent.width
          label: "Battery protection"
          description: root.chargeCapability.description
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          checked: root.chargeLimitEnabled
          enabled: !root.chargeBusy
          hasCursor: root.cursorOnCharge
          onClicked: root.setChargeLimit(!root.chargeLimitEnabled)
          onHovered: function (h) {
            if (h) {
              root.cursorRow = root.headKeys.indexOf("charge");
              root.cursorIndex = 0;
            }
          }
        }

        Toggle {
          visible: root.hardware.clamshell
          width: parent.width
          label: "Keep running when the lid closes"
          description: root.lidBehavior.description
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          checked: root.settingsView.clamshell && root.externalScreen
          enabled: root.externalScreen
          opacity: root.externalScreen ? 1 : 0.55
          hasCursor: root.cursorOnClamshell
          onClicked: root.setClamshell(!root.settingsView.clamshell)
          onHovered: function (h) {
            if (h) {
              root.cursorRow = root.headKeys.indexOf("clamshell");
              root.cursorIndex = 0;
            }
          }
        }

        Text {
          visible: root.chargeNoteVisible
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.Wrap
          text: "Battery protection: " + root.chargeCapability.description
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Lid close behavior (undocked; docked is the clamshell
        // toggle above). Applied truth leads; controls pick the DESIRED
        // mode; the pending strip bridges the two until the elevated apply.
        Column {
          visible: root.hardware.clamshell
          width: parent.width
          spacing: Style.spacing.rowGap

          PanelSeparator {
            foreground: root.foreground
          }

          PanelSectionHeader {
            text: "LID CLOSE · UNDOCKED"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // Hero: the APPLIED sentence. Fades through lidSwap when the
          // applied mode changes; muted fallback before the first probe.
          Row {
            width: parent.width
            spacing: Style.spacing.lg

            Text {
              id: lidHeroGlyph
              textFormat: Text.PlainText
              text: root.lidState ? root.lidGlyph(root.lidState.mode) : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              id: lidHeroText
              visible: !!root.lidState
              textFormat: Text.PlainText
              text: root.lidHeroSentence
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              wrapMode: Text.Wrap
              width: parent.width - lidHeroGlyph.width - parent.spacing
            }
          }

          Text {
            visible: !root.lidState
            textFormat: Text.PlainText
            text: "Checking the lid configuration…"
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Sleep-drain read-out: the story is suspend pays, hibernate
          // doesn't. Side by side, same grid as the battery stats row.
          Row {
            visible: root.lidHasHistory
            width: parent.width
            spacing: Style.spacing.huge

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap
              InfoPair {
                label: root.lastSleepLabel()
                value: root.lastSleepText()
              }
              InfoPair {
                label: "Sleep drain"
                value: root.drainText("suspend")
              }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap
              InfoPair {
                label: "Hibernate drain"
                value: root.drainText("hibernate")
              }
              InfoPair {
                label: "Sleep log"
                value: root.lidState && root.lidState.recording ? "on" : "off"
              }
            }
          }

          Text {
            visible: !root.lidHasHistory
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            text: root.lidState && root.lidState.recording ? "Recording sleep drain — no sleeps logged yet" : "No sleep drain recorded yet"
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Six exclusive modes, two rows of three (deterministic wrap),
          // System last. Buttons carry the DESIRED mode; exactly one active.
          Column {
            width: parent.width
            spacing: Style.spacing.md

            Row {
              id: lidModeRow1
              width: parent.width
              spacing: Style.spacing.md
              readonly property int indexOffset: 0
              readonly property real cellWidth: (width - spacing * 2) / 3

              Repeater {
                model: Model.LID_MODES.slice(0, 3)

                Button {
                  required property var modelData
                  required property int index
                  width: lidModeRow1.cellWidth
                  iconText: modelData.icon
                  iconSize: Style.font.title
                  text: modelData.label
                  fontSize: Style.font.bodySmall
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.spacing.xxs
                  bordered: true
                  active: root.settingsView.lidMode === modelData.value
                  enabled: root.lidModeEnabled(modelData.value)
                  opacity: enabled ? 1 : 0.45
                  tooltipText: enabled ? "" : "Needs hibernation setup"
                  hasCursor: root.cursorOnLid && root.cursorLidKind === 0 && root.cursorIndex === index + lidModeRow1.indexOffset
                  onClicked: root.setLidMode(modelData.value)
                  onHovered: function (h) {
                    if (h) {
                      root.cursorRow = root.headRows;
                      root.cursorIndex = index + lidModeRow1.indexOffset;
                    }
                  }
                }
              }
            }

            Row {
              id: lidModeRow2
              width: parent.width
              spacing: Style.spacing.md
              readonly property int indexOffset: 3
              readonly property real cellWidth: (width - spacing * 2) / 3

              Repeater {
                model: Model.LID_MODES.slice(3)

                Button {
                  required property var modelData
                  required property int index
                  width: lidModeRow2.cellWidth
                  iconText: modelData.icon
                  iconSize: Style.font.title
                  text: modelData.label
                  fontSize: Style.font.bodySmall
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.spacing.xxs
                  bordered: true
                  active: root.settingsView.lidMode === modelData.value
                  enabled: root.lidModeEnabled(modelData.value)
                  opacity: enabled ? 1 : 0.45
                  tooltipText: enabled ? "" : "Needs hibernation setup"
                  hasCursor: root.cursorOnLid && root.cursorLidKind === 0 && root.cursorIndex === index + lidModeRow2.indexOffset
                  onClicked: root.setLidMode(modelData.value)
                  onHovered: function (h) {
                    if (h) {
                      root.cursorRow = root.headRows;
                      root.cursorIndex = index + lidModeRow2.indexOffset;
                    }
                  }
                }
              }
            }
          }

          // Hibernation not set up: honest why + the fix (state 4).
          Row {
            visible: !root.lidHibernationReady
            width: parent.width
            spacing: Style.spacing.xs

            Text {
              id: lidSetupGlyph
              textFormat: Text.PlainText
              text: "󰀦"
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              text: "Smart and Hibernate need a hibernation setup — run `omarchy hibernation setup` to enable them."
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              width: parent.width - lidSetupGlyph.width - parent.spacing
            }
          }

          // Smart's hibernate delay + a rootless test of hibernate resume.
          Row {
            width: parent.width
            spacing: Style.spacing.md

            Dropdown {
              id: lidDelayControl
              width: Math.round((parent.width - parent.spacing) * 0.55)
              label: "Hibernate after"
              options: Model.lidDelayOptions()
              value: String(root.settingsView.hibernateDelayMin)
              enabled: root.settingsView.lidMode === "smart"
              opacity: enabled ? 1 : 0.45
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              hasCursor: root.cursorOnLid && root.cursorLidKind === 1 && root.cursorIndex === 0
              onChanged: function (v) {
                root.setLidDelay(Number(v));
              }
              onHovered: function (h) {
                if (h) {
                  root.cursorRow = root.headRows + 1;
                  root.cursorIndex = 0;
                }
              }
            }

            Button {
              id: lidTestBtn
              width: parent.width - parent.spacing - lidDelayControl.width
              text: "Test hibernate"
              leftAlign: true
              bordered: true
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.spacing.xxs
              enabled: root.lidHibernationReady
              opacity: enabled ? 1 : 0.45
              tooltipText: "Hibernates now — no password needed"
              hasCursor: root.cursorOnLid && root.cursorLidKind === 1 && root.cursorIndex === 1
              onClicked: root.testHibernate()
              onHovered: function (h) {
                if (h) {
                  root.cursorRow = root.headRows + 1;
                  root.cursorIndex = 1;
                }
              }
            }
          }

          // Pending strip: desired ≠ applied. Accent info, never urgent.
          Rectangle {
            id: lidStripRect
            visible: root.lidPending
            width: parent.width
            height: lidStripRow.implicitHeight + 2 * Style.spacing.rowPaddingX
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.foreground, Color.accent)
            border.width: 1
            border.color: Style.normalBorderFor(root.foreground, Color.accent)

            Row {
              id: lidStripRow
              anchors.fill: parent
              anchors.margins: Style.spacing.rowPaddingX
              spacing: Style.spacing.md

              Column {
                id: lidStripTexts
                width: parent.width - lidApplyItem.width - parent.spacing
                spacing: Style.spacing.xxs

                Text {
                  textFormat: Text.PlainText
                  text: "Picked " + Model.lidModeLabel(root.settingsView.lidMode) + (root.settingsView.lidMode === "smart" ? " (" + root.settingsView.hibernateDelayMin + " min)" : "") + " — not applied yet"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  wrapMode: Text.Wrap
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Apply opens a terminal and asks for your sudo password."
                  color: root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                  width: parent.width
                }
              }

              Item {
                id: lidApplyItem
                width: lidApplyBtn.width
                height: lidStripTexts.implicitHeight

                Button {
                  id: lidApplyBtn
                  anchors.centerIn: parent
                  text: "Apply — sudo password"
                  bordered: true
                  fontSize: Style.font.bodySmall
                  foreground: Color.accent
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.spacing.xxs
                  hasCursor: root.cursorOnLid && root.cursorLidKind === 2 && root.cursorIndex === 0
                  onClicked: root.applyLid()
                  onHovered: function (h) {
                    if (h) {
                      root.cursorRow = root.headRows + 2;
                      root.cursorIndex = 0;
                    }
                  }
                }
              }
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        Repeater {
          model: root.sources
          Column {
            id: sourceSection
            required property var modelData
            required property int index
            readonly property string src: String(modelData)
            readonly property bool current: root.source === src
            readonly property string profileKey: Model.sourceKey(src, "profile")
            readonly property string kbdKey: Model.sourceKey(src, "kbdBacklight")
            width: parent.width
            spacing: Style.spacing.rowGap

            PanelSeparator {
              visible: sourceSection.index > 0
              foreground: root.foreground
            }

            PanelSectionHeader {
              text: Model.sourceHeader(sourceSection.src, sourceSection.current, root.sources)
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              id: profileRow
              width: parent.width
              spacing: Style.spacing.md
              readonly property real cellWidth: root.profileOptions.length > 0 ? (width - spacing * (root.profileOptions.length - 1)) / root.profileOptions.length : 0

              Repeater {
                model: root.profileOptions
                Button {
                  required property var modelData
                  required property int index
                  width: profileRow.cellWidth
                  iconText: modelData.icon
                  iconSize: Style.font.title
                  text: modelData.label
                  fontSize: Style.font.bodySmall
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.spacing.xxs
                  bordered: true
                  active: root.settingsView[sourceSection.profileKey] === modelData.value
                  hasCursor: root.cursorSource === sourceSection.index && root.cursorKind === 0 && root.cursorIndex === index
                  onClicked: root.setProfile(sourceSection.src, modelData.value)
                  onHovered: function (h) {
                    if (h) {
                      root.cursorRow = root.headRows + sourceSection.index * root.rowsPerSource;
                      root.cursorIndex = index;
                    }
                  }
                }
              }
            }

            Row {
              id: delayRow
              width: parent.width
              spacing: Style.spacing.md
              readonly property real cellWidth: (width - spacing * (root.delayFields.length - 1)) / root.delayFields.length

              Repeater {
                model: root.delayFields
                Dropdown {
                  id: delayDropdown
                  required property var modelData
                  required property int index
                  readonly property string field: String(modelData)
                  readonly property string key: Model.sourceKey(sourceSection.src, field)
                  width: delayRow.cellWidth
                  readonly property bool lockNever: field === "sleep" && root.settingsView[Model.sourceKey(sourceSection.src, "lock")] === Model.NEVER
                  label: field === "screensaver" ? "Screensaver" : (field === "lock" ? "Lock" : "Sleep after lock")
                  // Sleep is armed only after the lock fired: with lock never it
                  // cannot happen, so the control is shown but disabled.
                  enabled: !lockNever
                  opacity: lockNever ? 0.45 : 1
                  options: Model.delayOptions(root.settingsView[key])
                  value: String(lockNever ? Model.NEVER : root.settingsView[key])
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  hasCursor: root.cursorSource === sourceSection.index && root.cursorKind === 1 && root.cursorIndex === index
                  onChanged: function (v) {
                    root.setDelay(sourceSection.src, field, v);
                  }
                  onHovered: function (h) {
                    if (h) {
                      root.cursorRow = root.headRows + sourceSection.index * root.rowsPerSource + 1;
                      root.cursorIndex = index;
                    }
                  }
                  Component.onCompleted: root.registerDelayControl(sourceSection.index, index, delayDropdown)
                }
              }
            }

            // Keyboard backlight per source: dropdown over the LED's own
            // steps on a coarse keyboard, percents otherwise.
            Row {
              id: kbdRow
              visible: root.kbdAvailable
              width: parent.width
              spacing: Style.spacing.md

              Dropdown {
                id: kbdDropdown
                width: parent.width
                label: "Keyboard backlight"
                options: Model.kbdOptions(root.kbdMax, root.settingsView[sourceSection.kbdKey])
                value: String(root.settingsView[sourceSection.kbdKey])
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                hasCursor: root.cursorSource === sourceSection.index && root.cursorKind === 2 && root.cursorIndex === 0
                onChanged: function (v) {
                  root.setKbdSource(sourceSection.src, v);
                }
                onHovered: function (h) {
                  if (h) {
                    root.cursorRow = root.headRows + sourceSection.index * root.rowsPerSource + 2;
                    root.cursorIndex = 0;
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    width: parent.width
    spacing: Style.spacing.lg
    Text {
      id: pairLabel
      textFormat: Text.PlainText
      text: label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item {
      width: Math.max(0, parent.width - pairLabel.implicitWidth - pairValue.implicitWidth - parent.spacing * 2)
      height: 1
    }
    Text {
      id: pairValue
      textFormat: Text.PlainText
      text: value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
