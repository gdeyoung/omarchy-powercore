#!/usr/bin/env bash
# PowerCore installer for Omarchy 4.x
# Installs the plugin (service + bar widget), enables it, places it in the
# bar's right section after the tray, and disables the stock omarchy.power
# widget (PowerCore supersedes it). Non-destructive: the plugin dir is
# copied, never deleted on upgrade.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_id="gdeyoung.powercore"
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"

say()  { printf '%s\n' "$*"; }

# --- 1. Install files ---------------------------------------------------------
mkdir -p "$plugin_dir"
install -m 644 "$repo_dir/Model.js"       "$plugin_dir/Model.js"
install -m 644 "$repo_dir/Service.qml"    "$plugin_dir/Service.qml"
install -m 644 "$repo_dir/BarWidget.qml"  "$plugin_dir/BarWidget.qml"
install -m 644 "$repo_dir/Panel.qml"      "$plugin_dir/Panel.qml"
install -m 644 "$repo_dir/manifest.json"  "$plugin_dir/manifest.json"
install -m 644 "$repo_dir/README.md"      "$plugin_dir/README.md"
install -m 644 "$repo_dir/LICENSE"        "$plugin_dir/LICENSE"
install -m 755 "$repo_dir/powerdraw.sh"   "$plugin_dir/powerdraw.sh"
say "installed: $plugin_dir"

# --- 2. Sampler sanity check --------------------------------------------------
if out=$("$plugin_dir/powerdraw.sh" 2>/dev/null); then
  case "$out" in
    battery\ *|gpu\ *|none) say "probe ok: $out" ;;
    *) say "WARNING: unexpected sampler output: $out" >&2 ;;
  esac
else
  say "WARNING: powerdraw.sh failed to run" >&2
fi

# --- 3. Enable + place --------------------------------------------------------
omarchy plugin enable "$plugin_id" 2>/dev/null || say "NOTE: run 'omarchy plugin enable $plugin_id' after shell restart"
omarchy bar put "$plugin_id" --section right 2>/dev/null || true

# --- 4. Retire the stock power widget if present ------------------------------
if omarchy plugin list 2>/dev/null | grep -q "omarchy.power"; then
  omarchy plugin disable omarchy.power 2>/dev/null && say "disabled: omarchy.power (superseded by PowerCore)" || true
fi

say ""
say "Done. Restart the shell to load the plugin:  omarchy restart shell"
