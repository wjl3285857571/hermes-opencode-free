#!/bin/bash
# Install the OpenCode free-tier bridge as a resident pair (serve + bridge) plus an hourly
# model-list sync, and register the provider in every Hermes profile that exists.
#
# Idempotent: re-running overwrites the scripts and plists and re-registers the provider.
set -euo pipefail

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
NODE_BIN="$(command -v node || true)"
OC_CLI=/Applications/OpenCode.app/Contents/Resources/opencode-cli
DEFAULT_PORT=4600
BRIDGE_PORT=5577
PROVIDER=opencode-free
# launchd Labels are dot-separated; keep them distinct from the provider key.
LABEL_SLUG=opencodefree

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$HERMES_ROOT/profiles/agents-md-code/tools/$PROVIDER"
HERMES_BIN="$HERMES_ROOT/.hermes/bin/hermes"

[ -x "$OC_CLI" ] || die "opencode CLI not found at $OC_CLI (install OpenCode.app first)"
[ -n "$NODE_BIN" ] || die "node not found on PATH"
[ -x "$HERMES_BIN" ] || HERMES_BIN="$(command -v hermes || true)"
[ -n "$HERMES_BIN" ] || die "hermes CLI not found"

say "==> installing scripts to $PROFILE_DIR"
mkdir -p "$PROFILE_DIR"
cp "$SRC/bridge/bridge.mjs" "$SRC/bridge/run-serve.sh" "$SRC/bridge/refresh-models.sh" "$PROFILE_DIR/"
chmod +x "$PROFILE_DIR/run-serve.sh" "$PROFILE_DIR/refresh-models.sh"

# The plists are rewritten with real paths rather than copied, so this repo is portable.
say "==> writing launchd agents"
mkdir -p "$HOME/Library/LaunchAgents"

sed -e "s#__DIR__#$PROFILE_DIR#g" \
    -e "s#__NODE__#$NODE_BIN#g" \
    -e "s#__PORT__#$DEFAULT_PORT#g" \
    "$SRC/launchd/local.hermes.opencodefree.serve.plist" \
    > "$HOME/Library/LaunchAgents/local.hermes.$LABEL_SLUG.serve.plist"

sed -e "s#__DIR__#$PROFILE_DIR#g" \
    -e "s#__NODE__#$NODE_BIN#g" \
    -e "s#__BRIDGE_PORT__#$BRIDGE_PORT#g" \
    -e "s#__SERVE_PORT__#$DEFAULT_PORT#g" \
    -e "s#__PATH__#$(dirname "$NODE_BIN"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin#g" \
    "$SRC/launchd/local.hermes.$LABEL_SLUG.bridge.plist" \
    > "$HOME/Library/LaunchAgents/local.hermes.$LABEL_SLUG.bridge.plist"

sed -e "s#__DIR__#$PROFILE_DIR#g" \
    "$SRC/launchd/local.hermes.$LABEL_SLUG.refresh.plist" \
    > "$HOME/Library/LaunchAgents/local.hermes.$LABEL_SLUG.refresh.plist"

for label in serve bridge refresh; do
  plist="$HOME/Library/LaunchAgents/local.hermes.$LABEL_SLUG.$label.plist"
  plutil -lint "$plist" >/dev/null
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load -w "$plist"
  say "    loaded local.hermes.$LABEL_SLUG.$label"
done

say "==> waiting for the chain to come up"
for _ in $(seq 1 30); do
  sleep 1
  free=$(curl -s --max-time 3 "http://127.0.0.1:$BRIDGE_PORT/healthz" 2>/dev/null || true)
  case "$free" in *'"ok":true'*) break ;; esac
done
curl -s --max-time 5 "http://127.0.0.1:$BRIDGE_PORT/healthz" || die "bridge did not come up"
say ""

say "==> registering provider in every Hermes profile"
# The bridge derives its live model list from /v1/models, so register first and let
# refresh-models.sh fill in the ids — hardcoding them would go stale the moment
# OpenCode delists a model.
for home in "$HERMES_ROOT" "$HERMES_ROOT"/profiles/*/; do
  [ -f "$home/config.yaml" ] || continue
  label=$(basename "${home%/}")
  [ "$label" = ".hermes" ] && label="default"
  env HERMES_HOME="${home%/}" "$HERMES_BIN" config set \
    "providers.$PROVIDER.api" "http://127.0.0.1:$BRIDGE_PORT/v1" >/dev/null
  env HERMES_HOME="${home%/}" "$HERMES_BIN" config set \
    "providers.$PROVIDER.default_model" "mimo-v2.6-flash-free" >/dev/null
  env HERMES_HOME="${home%/}" "$HERMES_BIN" config set \
    "providers.$PROVIDER.discover_models" "true" >/dev/null
  say "    registered in [$label]"
done

HERMES_BIN="$HERMES_BIN" "$PROFILE_DIR/refresh-models.sh" || die "model sync failed"

say ""
say "==> verifying end to end"
if env -u HERMES_HOME "$HERMES_BIN" chat -q "Reply with exactly: OCBRIDGE_INSTALL_OK" \
     --provider "$PROVIDER" --model mimo-v2.6-flash-free 2>&1 | grep -q "OCBRIDGE_INSTALL_OK"; then
  say "    Hermes -> bridge -> opencode -> free tier: OK"
else
  say "    WARNING: the chain did not answer. Check:"
  say "      launchctl list | grep $PROVIDER"
  say "      tail $PROFILE_DIR/bridge.log $PROFILE_DIR/serve.log"
  exit 1
fi

cat <<EOF

Done.

  Fully quit the Hermes desktop app (Cmd-Q) and relaunch it — it reads config.yaml
  at startup. The provider shows up under custom endpoints as "$PROVIDER".

  Use it:
    hermes chat -q "hello" --provider $PROVIDER --model mimo-v2.6-flash-free

  Uninstall:
    $SRC/uninstall.sh
EOF
