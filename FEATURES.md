# Coffee & Pi — feature requirements

Source of truth from product chats, including backend transcript
`35f4f953-d626-4a35-96c9-30ee24471562`.

## Core product

- [x] First-launch onboarding — pick engines (local / MLX / OpenAI·ChatGPT / Claude / OpenRouter / Grok / Cursor), connect 1-by-1, install Pi + llama router (+ optional mlx-lm), then tour Beans / Projects / Coffee Shop (phone pairing omitted for now; Skip anytime; Settings → Replay)
- [x] Mac app = Pi chat (Grok Bot–clean UI)
- [x] Real Pi embedded (`pi --mode rpc`)
- [x] Local llama.cpp multi-model router under the app (no Ollama)
- [x] Launch / attach router on app start
- [x] Model picker + thinking levels on composer
- [x] Import cloud subs via Pi auth UI (Codex / Claude / Grok / OpenRouter / …)
- [x] Local-only works with zero cloud subs
- [x] Full user agency (sandbox off)
- [x] Projects / Beans / Chats — beans & chats can live in or out of projects; Settings at sidebar bottom
- [x] Bean onboarding = Grokbot-style: choose a name (+ look) → chat opens → bean greets from the name alone
- [x] Archive / delete beans & chats (⋯ on row + context menu; restore in Settings → Archived)
- [x] Usage tracker — local turn counts per provider; live OpenRouter credits in Settings → Usage
- [x] GitHub connect / detect / open
- [x] Self-edit bots (cwd = project; `Scripts/rebuild-and-relaunch.sh`)

## Backend / local models (transcript 35f4f953)

- [x] Paste Hugging Face link / `owner/repo[:QUANT]` and download through router
- [x] Per-model context length
- [x] Per-model K / V cache quant
- [x] Per-model autocompaction
- [x] Per-model editable system prompt
- [x] Auto context length from hardware (`llama-fit-params` + heuristic fallback)
- [x] Profiles in `~/Library/Application Support/CoffeeAndPi/model-profiles.json`
- [x] Presets written to `~/models/presets.ini`

## Persistence / sessions

- [x] Persist chats across relaunch (`…/CoffeeAndPi/chats.json`)
- [x] Real Pi sessions (`--session-dir` + `--session-id`, not `--no-session`)
- [x] Resume / hydrate messages via `get_messages`

## Bean-to-bean chat + presence (backend for coffee-shop UI)

Shared **table** rooms and **transcript handoff**. Coffee-shop floor viz binds to `app.presence`.

### APIs on `AppModel`

| API | Purpose |
|-----|---------|
| `createTableChat(beanIDs:projectID:)` | Start a multi-Bean table thread |
| `inviteBean(_:to:)` / `removeBean(_:from:)` | Seat changes |
| `runTableTurn(threadID:trigger:onlyBeanIDs:)` | One sequential round of Bean replies |
| `beansKeepTalking()` | Another round on the active table |
| `workWith(threadID:into:)` | Attach another chat’s transcript as handoff |
| `tableThreads` | All `kind == .table` chats |
| `presence` (`BeanPresenceStore`) | `idle` / `walking` / `seated` / `speaking` / `handoff` |

### Data

- `ChatThread.kind` = `.solo` \| `.table`
- `participantBeanIDs`, `linkedThreadIDs`
- `ChatMessage.speakerBeanID`
- Pi clients keyed by `BeanClientKey(threadID, beanID)`; session id `piSessionID-beanUUID`

### UI hooks

- Bean context menu: start table / invite to table
- Composer: `@Bean` invites, **Talk among yourselves**, **Work with** (chats + Cursor `.jsonl`)
- Table header shows seats + provider chips + presence
- **Coffee Shop** sidebar pane: floor plan, Bean motion from `presence`, tables, Seat the house

### Coffee Shop APIs (UI)

| API | Purpose |
|-----|---------|
| `openShop(projectID:)` | House lobby (`nil`) or a project café |
| `shopBeans()` / `shopChats()` / `shopTables()` | Scoped floor contents |
| `seatTheHouse(projectID:)` | Ensure Local + Codex + Cursor Beans in scope |
| `workWithTranscriptFile(at:into:)` | Attach Cursor/agent JSONL as handoff |

- [x] Table turn-taking + persistence
- [x] Transcript handoff
- [x] Presence bus for coffee-shop UI
- [x] Coffee-shop floor plan / movement
- [x] House lobby + per-project coffee shops
- [x] Solo chats as floor cards in the active shop

## Remote devices (node API)

Each Mac is its own server. No Coffee & Pi accounts — pair with QR or device-code OAuth against that Mac.

- [x] Local node HTTP + WebSocket server (port `9932`)
- [x] Pairing: QR + 6-digit code → bearer device token (`POST /v1/pair`)
- [x] Device OAuth: `POST /v1/oauth/device` + approve in Settings + `POST /v1/oauth/token`
- [x] Auth’d `GET /v1/health|nodes|models|chats`, `POST /v1/chats`, `POST /v1/chats/:id/messages`, `POST /v1/chats/:id/abort`, `WS /v1/ws?token=`
- [x] Thin client: phone only calls the node API; Pi + llama/cloud providers run on the Mac
- [x] WebSocket push of chat/stream state to subscribed devices (`subscribe` → `{type:chat}`)
- [x] Settings → Devices (enable, name, QR, code, pending approve, revoke)
- [x] Bonjour advertise `_coffeeandpi._tcp`
- [x] Off-LAN reachability via Tailscale CGNAT (`100.64/10`) + optional public host (MagicDNS / tunnel) — no central login
- [x] Mobile client — thin web UI served at `http://<mac>:9932/` (pair → chats → WS stream)

### Mobile client contract (all work on the computer)

Phone / peer Mac must **not** run Pi or load models. Only:

1. Pair → bearer token  
2. `GET /v1/chats`, `POST /v1/chats`, `GET /v1/chats/:id`  
3. `POST /v1/chats/:id/messages` `{ "text": "..." }` → Mac runs the agent  
4. `WS /v1/ws?token=…` → `{ "type":"subscribe", "chatID":"…" }` for live tokens  
5. `POST /v1/chats/:id/abort` to stop  

Persistence: `~/Library/Application Support/CoffeeAndPi/node.json`

## Polish (shipped)

- [x] Self-edit → live UI closed loop (`Scripts/rebuild-and-relaunch.sh` stamps + app banner on relaunch; chats persist)
- [x] Sidebar search + richer chrome (search field, router/slots, solo chat header)
- [x] Composer mic (Speech framework dictation)
- [x] Multi-slot capacity UX when several small models fit (slots label + Settings picker 1–8)
- [x] Cloud catalog after import fully verified in picker (`refreshCloudCatalog` + disk seed + live probe)
- [x] Off-LAN node reachability (see Remote devices)
- [x] Mobile thin client (see Remote devices)
