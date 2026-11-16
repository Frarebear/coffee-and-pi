# Coffee & Pi

macOS SwiftUI app: **Pi chat** with a Grok Bot–clean UI, backed by a local **llama.cpp multi-model router** (no Ollama).

## Stack

| Layer | Role |
|-------|------|
| Coffee & Pi (SwiftUI) | Chat UI, model + thinking pickers, subscriptions, router status |
| Pi (`pi --mode rpc`) | Real Pi agent (tools, auth, sessions) — one RPC process per chat |
| llama.cpp router | Local models on `http://127.0.0.1:9931` |

## Features (v1)

- **First-launch onboarding**: pick local / MLX / OpenAI·ChatGPT / Claude / OpenRouter / Grok / Cursor, connect one-by-one, tour Beans · Projects · Coffee Shop (phone pairing later; Settings → Replay)
- Launch starts / attaches to the local router
- Multi-chat (multiple Pi RPC sessions; router `models-max` defaults to 2)
- Composer model dropdown (router models synced into Pi) + thinking levels
- **Projects** with **Beans** (agents per project or loose)
- **GitHub** connect via `gh` / detect `origin` remote
- Import provider subs via Pi’s existing `pi auth login`
- Local-only works with no cloud subs imported
- **Self-edit**: bots can edit this repo and run `Scripts/rebuild-and-relaunch.sh`
- **Remote devices**: Settings → Devices enables a node API (`http://<mac>:9932`) — QR / code pairing, thin phone web UI at `/`, Tailscale / optional public host for off-LAN. No central account. See `FEATURES.md`.

## Dev

```bash
# Generate Xcode project
xcodegen generate

# Build & run
open CoffeeAndPi.xcodeproj
# or:
xcodebuild -scheme CoffeeAndPi -configuration Debug -derivedDataPath build build
open "build/Build/Products/Debug/Coffee & Pi.app"
```

Requires: Xcode 15+, `pi` on PATH (`~/.npm-global/bin/pi`), `llama-router` at `~/.local/bin/llama-router`, models/presets under `~/models/`.

## Config already on this machine

- Router: LaunchAgent `com.caleb.llama-router` + `~/models/presets.ini`
- Pi: `~/.pi/agent/` → `llama.cpp` / `gemma4-heretic`
