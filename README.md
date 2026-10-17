# hermes-opencode-free

Use OpenCode's **zero-cost model tier** as an LLM backend for [Hermes Agent](https://github.com/NousResearch/hermes-agent), on macOS, with no API key.

OpenCode closed anonymous access to its free tier on 2026-09-18 — every third-party client now gets
`HTTP 403 FreeTierError` straight from the relay. This project routes through OpenCode's **own
headless server** instead, which is what makes the free tier answer again.

```
Hermes  ──▶  bridge.mjs  ──▶  opencode serve  ──▶  OpenCode Zen free tier
           (OpenAI-shaped)     (the real client)      9 models · cost 0
             :5577                 :4600
```

## Why a bridge is needed at all

`opencode serve` exposes **no OpenAI-compatible surface**. Its OpenAPI spec lists 118 routes and
none of them is `/v1/chat/completions` or `/v1/models` — the API is `/api/session`,
`/api/session/{id}/prompt`, `/api/session/{id}/message`, all behind HTTP basic auth with a
password the server generates fresh on every start.

So the bridge translates:

| OpenAI | opencode serve |
|---|---|
| `GET /v1/models` | `GET /api/model`, filtered to `*-free` |
| `POST /v1/chat/completions` | `POST /api/session` → `POST /api/session/{id}/model` → `POST /api/session/{id}/prompt` → poll `GET /api/session/{id}/message` |

There is no one-shot "post and get the reply" call: v2 accepts the prompt and then you poll for the
assistant message.

## Measured numbers

Same machine, trivial prompts:

| | Latency |
|---|---|
| First call (cold session) | ~16 s |
| Warm calls | ~8–17 s |
| Full Hermes turn | ~21 s |

Cost: **0**. Nine free models at time of writing:

```
mimo-v2.6-flash-free            deepseek-v4.1-flash-free
glm-5.3-flash-free              nemotron-3-ultra-free
nemotron-3.5-lightning-free     nemotron-3.5-super-vl-free
space-bunny-free                beam-free
longcat-2.5-preview-free
```

## Install

Requirements: macOS, OpenCode's app installed, Node.js on `PATH`.

```bash
git clone https://github.com/wjl3285857571/hermes-opencode-free
cd hermes-opencode-free
./install.sh
```

The installer copies the scripts, writes three launchd agents, registers the provider in every
Hermes profile that exists, and verifies the chain end to end. It prints a rollback command.

Then **fully quit and relaunch the Hermes desktop app** (⌘Q, not just close the window) — it reads
`config.yaml` at startup. The provider appears under **custom endpoints** as `OPENCODE-FREE`.

It is deliberately *not* named `opencode`: that key is Hermes's existing alias for the **paid**
`opencode-zen` provider (`hermes_cli/providers.py` maps `"opencode" -> ("opencode-zen", "zen")`),
so reusing it would collide with the paid route. The key also reuses the name of the dead
built-in `opencode-free` provider, which upstream removed — which is exactly the right home for a
free route. Its launchd labels use `opencodefree` (dots, no dashes) per launchd convention.

```bash
hermes chat -q "hello" --provider opencode-free --model mimo-v2.6-flash-free
```

## Uninstall

```bash
./uninstall.sh
```

## How the three launchd agents fit

| Label | Role |
|---|---|
| `local.hermes.opencodefree.serve` | Runs `opencode serve`, captures its rotating password |
| `local.hermes.opencodefree.bridge` | Runs `bridge.mjs` on `:5577` |
| `local.hermes.opencodefree.refresh` | Hourly: syncs the live model list into every profile |

All three are `LimitLoadToSessionType: Aqua` — they only run inside a logged-in GUI session, since
the serve half is an interactive-client component.

## Why the model list is synced rather than hardcoded

Hermes' `/model` picker **never live-probes a custom endpoint**. The probe endpoint
(`POST /api/providers/custom-endpoints/validate`) fires only when a human clicks "test connection"
in settings. So a provider under `providers:` has to list its models explicitly — but OpenCode
delists models on its own schedule (`ll-alpha-free` disappeared mid-session during development),
and a frozen list would keep offering a slug that 403s.

`refresh-models.sh` copies the bridge's live catalog into every profile that declares the provider,
hourly. Run it by hand to force a sync:

```bash
./bridge/refresh-models.sh
```

It skips profiles without an `opencode-free` entry, so it never writes config where the provider is
unused. It writes through `hermes config set` — never by editing `config.yaml` directly, which is a
hard Hermes rule (one stray indent can take down the live gateway).

## Gotchas this encodes

Each of these cost real debugging time; all are commented at the relevant line.

- **Model ids on the wire are bare.** `POST /api/session/{id}/model` takes
  `{providerID, modelID, id}` and the server composes the id itself. Sending a pre-joined
  `opencode/<model>` doubles the prefix, and **both mistakes report the same string**
  (`Model unavailable: opencode/opencode/<model>`), so the error cannot tell you which you made.
  Copy ids from `/api/model` rather than composing them.
- **Sessions are pinned to a model.** The bridge keeps one session per model id, and drops a
  session whose model turns out to be delisted — otherwise a poisoned session replays its failure
  forever.
- **Poll by message id, not array position.** opencode inserts a turn's messages anywhere in the
  list; slicing by prior length silently misses them and the request hangs until timeout.
- **`OPENCODE_SERVER_PASSWORD` does not work.** opencode 2.x ignores it and prints a random
  password at startup. `run-serve.sh` redirects to a log and greps it.
- **A `cmd | tee log | while read` pipeline does not work under launchd** — the while-loop never
  sees the lines, so the password file stays empty and every request 401s. It works when you run
  it by hand, which is why this only shows up once you go resident.
- **The bridge self-heals.** Started before `serve` is ready it reports `free: 0`; it re-reads the
  password file per request and re-fetches the catalog on the first call.

## Relationship to other routes

| Route | Status |
|---|---|
| Hermes built-in `opencode-zen` / `opencode-go` | ✅ work — but **paid** (`OPENCODE_ZEN_API_KEY`, or $10/mo for Go) |
| Restored `opencode-free` provider | ❌ 403 |
| Community `oc-free-provider` plugin (v3.0.0) | ❌ 403 |
| Direct relay access | ❌ 403 |
| **This bridge** | ✅ cost 0 |

The direct paths fail because the relay discriminates the *caller*, not the credential — three
different clients (Hermes, oh-my-pi, OmniRoute) all get the identical 403 with a valid key, while
the real OpenCode client answers at cost 0.

## Security posture

The bridge binds `127.0.0.1` only. OpenCode's password lands in `serve_password` with mode 600 and
is read per request; it never leaves the loopback interface. Full conversation text still travels
to OpenCode's servers, as it would for any inference provider.

## Files

```
bridge/bridge.mjs           the OpenAI-compatible adapter (Node stdlib only)
bridge/run-serve.sh         starts opencode serve and captures its rotating password
bridge/refresh-models.sh    syncs the live model list into every Hermes profile
launchd/*.plist             templates; install.sh substitutes the real paths
install.sh                  install + register + verify end to end
uninstall.sh                remove everything this added
```

Scripts derive their own location, so the repo works from any checkout path.

## Troubleshooting

```bash
DIR=~/.hermes/profiles/agents-md-code/tools/opencode-free

# is anything running?
launchctl list | grep opencode-free
curl -s localhost:5577/healthz
curl -s localhost:4600/api/health -u "opencode:$(cat "$DIR/serve_password")"

# logs
tail "$DIR"/serve.log "$DIR"/bridge.stdout.log "$DIR"/refresh.log

# force a model-list sync
"$DIR/refresh-models.sh"
```

`free: 0` in `/healthz` means serve was not up when the bridge started; it resolves on the first
request.
