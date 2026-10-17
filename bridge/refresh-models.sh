#!/bin/bash
# Re-sync the ocbridge model list into every Hermes profile that declares the provider.
#
# Why this exists: Hermes' /model picker never live-probes a custom endpoint — the
# /api/providers/custom-endpoints/validate probe only fires when a human clicks
# "test connection" in settings. So a provider under `providers:` must list its
# models explicitly. The bridge already discovers opencode's live catalog on every
# request, so this copies that catalog into config rather than freezing it by hand.
#
# Runs for every profile whose config already has providers.ocbridge, so it never
# creates the entry in a profile that does not use it.
set -u

BRIDGE="${OCBRIDGE_URL:-http://127.0.0.1:5577}"

payload=$(curl -s --max-time 20 "$BRIDGE/v1/models") || {
  echo "ocbridge: cannot reach $BRIDGE/v1/models" >&2
  exit 1
}

models=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    ids = [str(m.get("id") or "").strip() for m in json.load(sys.stdin).get("data", [])]
except Exception as e:
    sys.exit(f"unparseable /v1/models payload: {e}")
ids = [i for i in ids if i]
if not ids:
    sys.exit("/v1/models returned no model ids")
print("[" + ", ".join(f"\"{i}\"" for i in ids) + "]")
') || { echo "ocbridge: $models" >&2; exit 1; }

count=$(printf '%s' "$models" | tr -cd ',' | wc -c | tr -d ' ')
echo "ocbridge: discovered $((count + 1)) models"

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
# Prefer an explicit HERMES_BIN, then the per-install launcher, then PATH. Probing is safer
# than assuming: the launcher lives at a different path on different installs.
if [ -z "${HERMES_BIN:-}" ]; then
  for candidate in "$HERMES_ROOT/.hermes/bin/hermes" "$HERMES_ROOT/hermes-agent/.hermes/bin/hermes"; do
    [ -x "$candidate" ] && { HERMES_BIN="$candidate"; break; }
  done
fi
[ -n "${HERMES_BIN:-}" ] || HERMES_BIN="$(command -v hermes || true)"
[ -n "$HERMES_BIN" ] || { echo "ocbridge: no hermes CLI found (set HERMES_BIN)" >&2; exit 1; }

for home in "$HERMES_ROOT" "$HERMES_ROOT"/profiles/*/; do
  cfg="$home/config.yaml"
  [ -f "$cfg" ] || continue
  grep -q '^  ocbridge:' "$cfg" 2>/dev/null || continue

  label=$(basename "${home%/}")
  [ "$label" = ".hermes" ] && label="default"

  out=$(env HERMES_HOME="${home%/}" "$HERMES_BIN" config set providers.ocbridge.models "$models" 2>&1)
  case "$out" in
    *"Set"*) echo "  [$label] synced -> ${home%/}" ;;
    *)       echo "  [$label] FAILED: $out" >&2 ;;
  esac
done
