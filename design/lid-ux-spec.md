# Lid close behavior — UX spec (gdeyoung.powercore)

Approved expansion: new interactive section controlling what logind does when
the lid closes **undocked** (docked clamshell toggle above is unchanged).
Read-out is the hero; controls sit beneath. Content width `Style.space(440)`
(Panel.qml:328); Quickshell 0.3.2 / Qt6 / V4, plain Rectangle/Text/Row/Column/
Behavior, Nerd Font glyphs as plain Text. **Zero literal hex** — every color is
a Color role or Style state helper, so accent swaps and dark themes survive.

## 1. ASCII sketch (440px content width)

```
 󰌋 Keep running when the lid closes                 [ □ toggle ]   ← existing
 ────────────────────────────────────────────────────────────────  PanelSeparator
 LID CLOSE · UNDOCKED                                               PanelSectionHeader
 󰒲  Light sleep only — drains ~1% per hour                          hero (APPLIED)
 Last sleep      3 h 33 min · 96%→94%     Hibernate drain  0.1%/h · 2×
 Sleep drain     0.9%/h · 3×              Sleep log        on        InfoPair grid
 ┌───────────────┬───────────────┬───────────────┐
 │   󰔛 Smart     │   󰒲 Sleep     │  󰶘 Hibernate  │  ← disabled+dims when
 └───────────────┴───────────────┴───────────────┘    hibernationReady=false
 ┌───────────────┬───────────────┬───────────────┐
 │   󰌋 Lock      │  󰜺 Nothing    │   󰒏 System    │
 └───────────────┴───────────────┴───────────────┘
 Hibernate after   [ 60 min 󰅀 ]              [ Test hibernate ]
 ┌─────────────────────────────────────────────────────────────┐
 │ Picked Smart (30 min) — not applied yet         [Apply — sudo│  pending strip
 │ Apply opens a terminal and asks for your sudo…   [ password ]│  (only pending)
 └─────────────────────────────────────────────────────────────┘
 ────────────────────────────────────────────────────────────────  PanelSeparator
 ON BATTERY · NOW   …  (source sections untouched)
```

## 2. Element tree (exact components/props)

Inserts in the main `Column` after the charge-note Text, before the sources
`Repeater`; whole section `visible: root.hardware.clamshell`.

```qml
Column {                                    // width: parent.width
  spacing: Style.spacing.rowGap             // same as source sections
  PanelSeparator { foreground: root.foreground }
  PanelSectionHeader { text: "LID CLOSE · UNDOCKED"; foreground; fontFamily }

  Row { spacing: Style.spacing.lg           // hero = APPLIED truth, always first
    Text { text: lidGlyph(state.mode); font.pixelSize: Style.font.title; color: root.foreground }
    Text { text: Model.lidModeSummary(state.mode, state.delayMin)   // wraps, ≤2 lines
           font.pixelSize: Style.font.subtitle; font.bold: true; color: root.foreground
           wrapMode: Text.Wrap; width: parent.width - glyph.width - Style.spacing.lg }
  } // state null (probe not back): muted Text "Checking the lid configuration…", bodySmall

  Row { spacing: Style.spacing.huge; width: parent.width   // stats-row precedent (466)
    Column { width: (parent.width - parent.spacing) / 2; spacing: Style.spacing.labelGap
      InfoPair { label: "Last sleep";      value: lastSleepText() }  // "3 h 33 min · 96%→94%"
      InfoPair { label: "Sleep drain";     value: drainText("suspend") }   // "0.9%/h · 3×"
    }
    Column { width: (parent.width - parent.spacing) / 2; spacing: Style.spacing.labelGap
      InfoPair { label: "Hibernate drain"; value: drainText("hibernate") } // "0.1%/h · 2×" | "—"
      InfoPair { label: "Sleep log";       value: state.recording ? "on" : "off" }
    }
  }   // hidden when history empty → replaced by the state-7 line

  // Two Rows of three (not Flow): deterministic wrap; cellWidth math identical
  // to profileRow (601). Exactly one Button `active`.
  Column { spacing: Style.spacing.md
    Row { spacing: Style.spacing.md; Repeater { model: Model.LID_MODES.slice(0,3); Button {…} } }
    Row { spacing: Style.spacing.md; Repeater { model: Model.LID_MODES.slice(3);   Button {…} } }
  } // Button props: width: cellWidth; iconText: mode.icon; text: mode.label; bordered: true
    //   fontSize: Style.font.bodySmall; iconSize: Style.font.title
    //   horizontalPadding: controlPaddingX; verticalPadding: controlPaddingY + xxs
    //   active: settingsView.lidMode === mode.value        ← DESIRED (input)
    //   enabled: (mode.value==="smart"||mode.value==="hibernate") ? state.hibernationReady : true
    //   opacity: enabled ? 1 : 0.45                        // lockNever precedent
    //   tooltipText (Smart/Hibernate): "Needs hibernation setup"
    //   onClicked: service.setLidMode(mode.value); onHovered → set cursorRow/index

  Row { // state-4 note, visible: !state.hibernationReady
    Text { text: "󰀦"; color: Color.urgent; font.pixelSize: Style.font.bodySmall }
    Text { text: note; color: root.foreground; opacity: 0.7; font.pixelSize: Style.font.bodySmall
           wrapMode: Text.Wrap; width: parent.width - glyph.width - Style.spacing.xs }
  }

  Row { spacing: Style.spacing.md; width: parent.width
    Dropdown { width: Math.round((parent.width - parent.spacing) * 0.55)
      label: "Hibernate after"
      options: [{value:"15",label:"15 min"},{value:"30",label:"30 min"},{value:"60",label:"60 min"},
                {value:"120",label:"120 min"},{value:"180",label:"180 min"}]
      value: String(settingsView.hibernateDelayMin)        // object form: no re-parsing
      enabled: settingsView.lidMode === "smart"; opacity: enabled ? 1 : 0.45  // state 6
      hasCursor/foreground/accent/fontFamily wired like existing dropdowns
      onChanged: service.setLidDelay(Number(v)) }
    Button { width: parent.width - parent.spacing - dropdown.width; text: "Test hibernate"
      bordered: true; fontSize: Style.font.bodySmall; leftAlign: true
      enabled: state.hibernationReady; opacity: enabled ? 1 : 0.45
      tooltipText: "Hibernates now — no password needed"; onClicked: service.testHibernate() }
  }

  // Pending strip — visible: service.lidPendingNow. Plain Rectangle.
  Rectangle { width: parent.width; radius: Style.cornerRadius
    color: Style.selectedFillFor(root.foreground, Color.accent)     // accent @ selectedFillAlpha
    border.width: 1; border.color: Style.normalBorderFor(root.foreground, Color.accent)
    Row { anchors.fill: parent; anchors.margins: Style.spacing.rowPaddingX; spacing: md
      Column { width: parent.width - applyBtn.width - parent.spacing; spacing: xxs
        Text { text: "Picked " + Model.lidModeLabel(settings.lidMode)
               + (settings.lidMode === "smart" ? " (" + settingsView.hibernateDelayMin + " min)" : "")
               + " — not applied yet"                                  // e.g. "Picked Smart (30 min) — not applied yet"
               font.pixelSize: Style.font.body; font.bold: true; color: root.foreground }
        Text { text: "Apply opens a terminal and asks for your sudo password."
               font.pixelSize: Style.font.caption; color: root.foreground; opacity: 0.7
               wrapMode: Text.Wrap }
      }
      Button { id: applyBtn; text: "Apply — sudo password"; bordered: true
        foreground: Color.accent; accent: Color.accent; fontSize: Style.font.bodySmall
        verticalPadding: Style.spacing.controlPaddingY + Style.spacing.xxs
        onClicked: service.applyLid() }   // service no-ops if terminal already open
    }
  }
}
```

Glyphs (nf-md): smart `󰔛` timer — "sleep, then…" after a delay (the provisional
`󰖔` moon reads too close to suspend `󰒲` at 14px); suspend `󰒲`, hibernate `󰶘`, lock `󰌋`, ignore `󰜺`, system `󰒏` keep the owner's set.

## 3. The eight states

`state` = `service.lidState` (applied, from drop-ins); `settingsView` = desired.
fg = `root.foreground`. All controls enabled unless stated.

**1 · Fresh default** (mode=system desired+applied, recording off, no history,
hibernationReady=true): hero `󰒏  System default — sleeps when the lid closes`.
**System** active; delay dimmed (state-6 look), value `60 min`; drain line
`No sleep drain recorded yet` (fg, opacity 0.6, bodySmall); strip hidden; Test enabled.

**2 · Smart applied** (state.mode=smart, delayMin=60, recording on, desired=smart,
not pending): hero `󰔛  Sleeps, then hibernates after 60 min on battery`;
**Smart** active; delay enabled, `60 min`; drain if still empty
`Recording sleep drain — no sleeps logged yet`; strip hidden.

**3 · Pending** (desired ≠ applied; e.g. desired=hibernate, applied=suspend):
hero stays APPLIED — `󰒲  Light sleep only — drains ~1% per hour`. **Hibernate**
active (desired row = "your pick"). Strip visible, accent-tinted (never
`Color.urgent`): L1 `Picked Hibernate — not applied yet`; smart delay drift:
`Picked Smart (30 min) — not applied yet`; back to default: `Picked System —
not applied yet`. L2 `Apply opens a terminal and asks for your sudo password.`
Apply live.

**4 · Hibernation not ready** (`hibernationReady=false`): Smart + Hibernate
`enabled: false`, `opacity: 0.45` (active still honored if stale-desired). Test
dimmed + disabled, tooltip `Needs hibernation setup`. Note under the mode row,
fg opacity 0.7 + `󰀦` glyph in `Color.urgent`:
`Smart and Hibernate need a hibernation setup — run \`omarchy hibernation setup\` to enable them.`
Everything else (states 1–3, 7–8) renders unchanged around it.

**5 · No lid (desktop)**: `hardware.clamshell === false` → section and its
leading PanelSeparator `visible: false`; zero cursor rows. Same flag that hides
the clamshell toggle.

**6 · Delay while mode ≠ smart**: Dropdown visible but `enabled: false`,
`opacity: 0.45` (exact precedent: lockNever, Panel.qml:646–651). Value still
shown — recognition over recall; the setting survives dimmed.

**7 · Drain empty** (history length 0): InfoPair grid replaced by one line,
fg opacity 0.6, bodySmall:
- recording on: `Recording sleep drain — no sleeps logged yet`
- recording off: `No sleep drain recorded yet`

**8 · Drain with data**: InfoPair grid (§2). `Last sleep` →
`3 h 33 min · 96%→94%`; hibernate last: label `Last hibernate`, value
`7 h 12 min · 88%→88%`. Minutes: `X h Y min` (under 60: `Y min`). Type word:
suspend→`sleep`, hibernate→`hibernate`. `Sleep drain` → `0.9%/h · 3×`;
`Hibernate drain` → `0.1%/h · 2×`; a null side → `—` (drainLabel(null)) — the
side-by-side is the story: sleep pays, hibernate doesn't. `Sleep log` → `on`/`off`.

## 4. Typography · spacing · radius

| Element | Role |
|---|---|
| Section header | `Style.font.caption` (component default, bold) |
| Hero glyph / sentence | `Style.font.title` / `Style.font.subtitle` bold, wraps |
| InfoPair labels+values, empty/note/pending-L2 | `Style.font.bodySmall` |
| Mode/Test/Apply buttons; icons | `Style.font.bodySmall`; `Style.font.title` |
| Dropdown label/value; pending L1 | component defaults (caption/body); `Style.font.body` bold |

Spacing: section Column `rowGap`; hero Row `lg`; mode Rows `md`, cellWidth
`(width − 2·md)/3`; delay Row `md` (dropdown 55%, Test remainder); drain Row
`huge`, columns `(width − huge)/2`, pairs `labelGap`; strip inset `rowPaddingX`,
inner `xxs`; buttons per profile recipe. Radius: `Style.cornerRadius` on strip +
kit controls. Nothing else.

## 5. Color decisions

- Mode buttons: Button defaults — `active`/`selected` fill + bold selected text
  from `Style.selectedFillFor/hoverFillFor(foreground, Color.accent)`.
- Disabled (states 4/6, Test): `opacity: 0.45` + `enabled: false` — conveyed by
  size+opacity+tooltip, never color alone (WCAG 1.4.1).
- Pending strip: `Style.selectedFillFor(fg, Color.accent)` fill,
  `Style.normalBorderFor(fg, Color.accent)` border — accent info, not urgent:
  pending is a status, not an error. Apply button: `foreground: Color.accent` —
  the section's only accent label, reserving accent for the elevation action.
- State-4 `󰀦` glyph `Color.urgent`, body text fg — one red glyph, no red prose.
  No hex anywhere; a theme change re-resolves accent/urgent/fg via the same
  helpers the rest of the panel already uses.

## 6. Motion (Behavior/PropertyAnimation only)
Strip: `Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }`;
height snaps (no relayout jank). Hero sentence swap on applied-mode change:
phraseSwap pattern — fade →0 (180ms OutQuad), swap text, fade →1 (260ms
InQuad). Buttons/dropdowns use the kit's built-in 120ms ColorAnimation; no
loops/pulses — static truth, not live telemetry.

## 7. Keyboard cursor grid (extends moveCursor/activateCursor)

After `headRows` (charge, clamshell), only when `hardware.clamshell`. Rows:
kind 0 = mode buttons (2 visual Rows, ONE logical row, 6 cells in `LID_MODES`
order; activate → `setLidMode(LID_MODES[i].value)`, no-op if disabled);
kind 1 = delay row (2 cells: dropdown → `open()` if enabled, Test →
`testHibernate()` if enabled); kind 2 = apply row (1 cell → `applyLid()`),
exists **only while pending**.

Left/right wraps 0–5 across both visual Rows (`hasCursor: cursorIndex ===
index` in both Repeaters); sources shift: `sourceBase = headRows + lidRows`;
pending flips false while the cursor is on the apply row → park `cursorRow = -1`;
hover sets row/index like the profile buttons.

## 8. Rationale (major decisions)

- **Hero = applied sentence; buttons = desired, never mixed; strip bridges
  them** — NN/g *visibility of system status* (the panel answers "what happens
  if I close the lid now?" before offering choices) + Nielsen *mapping* and
  *error prevention*: control reflects input, readout reflects reality, drift
  stays legible instead of blurring.
- **Six modes as 3×2, System last** — Hick's law (grouping + default anchor) ×
  Gestalt *similarity* (sibling rhythm to Eco/Balanced/Performance rows).
- **Apply: distinct bordered accent action, present only while pending; accent
  tint for the strip, urgent reserved for the setup glyph** — Fitts (one large
  end-of-section target) + recognition over recall (button text "Apply — sudo
  password" makes the terminal expected, not alarming) + WCAG 1.4.1 /
  seamfulness: informative friction, not an error.
- **Dimmed-not-hidden delay; %/h side by side** — recognition over recall
  (lockNever precedent) + Gestalt *proximity*: the Smart argument in one glance.

## 9. Implementation guards

- V4-safe: `slice`, `Number`, string concat only; duration formatter inline in
  Panel.qml; no .js imports, no computed keys. Dropdown options as
  `{value,label}` objects so `onChanged` returns `"60"` — no parsing.
- `service.lidState` null pre-probe → hero falls back to the muted
  `Checking the lid configuration…` line; controls stay live (desired is
  settings-backed, instant, no root). Bar widget, clamshell toggle, source
  sections untouched; `contentHeight` follows `column.implicitHeight` already.
