#!/bin/bash
# Remove the bridge: unload the launchd agents, delete their plists and scripts, and drop the
# provider from every Hermes profile. The bridge's model list is the only state it owns, so
# there is nothing else to clean up.
set -uo pipefail

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
PROVIDER=ocbridge
PROFILE_DIR="$HERMES_ROOT/profiles/agents-md-code/tools/$PROVIDER"
HERMES_BIN="$HERMES_ROOT/.hermes/bin/hermes"

[ -x "$HERMES_BIN" ] || HERMES_BIN="$(command -v hermes || true)"

echo "==> unloading launchd agents"
for label in serve bridge refresh; do
  plist="$HOME/Library/LaunchAgents/local.hermes.$PROVIDER.$label.plist"
  if [ -f "$plist" ]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "    removed local.hermes.$PROVIDER.$label"
  fi
done

echo "==> removing scripts"
if [ -d "$PROFILE_DIR" ]; then
  rm -rf "$PROFILE_DIR"
  echo "    removed $PROFILE_DIR"
fi

if [ -n "$HERMES_BIN" ]; then
  echo "==> dropping the provider from every profile"
  for home in "$HERMES_ROOT" "$HERMES_ROOT"/profiles/*/; do
    [ -f "$home/config.yaml" ] || continue
    label=$(basename "${home%/}")
    [ "$label" = ".hermes" ] && label="default"
    grep -q "^  $PROVIDER:" "$home/config.yaml" 2>/dev/null || continue
    env HERMES_HOME="${home%/}" "$HERMES_BIN" config unset "providers.$PROVIDER" 2>&1 | tail -1
    echo "    [$label] done"
  done
fi

echo ""
echo "Uninstalled. OpenCode itself is untouched."
