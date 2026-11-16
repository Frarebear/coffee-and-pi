# Coffee & Pi — agent notes

You are running inside the **Coffee & Pi** Mac app (Pi RPC), usually with cwd at this repo.

## Self-edit

- You **may** edit anything in this project, including `Sources/` (SwiftUI app).
- After UI or app code changes, rebuild and relaunch:

```bash
Scripts/rebuild-and-relaunch.sh
```

- Prefer small working diffs. Don’t ask for permission to edit this repo when the bot has self-edit enabled.
- App updates: `Scripts/release.sh [version]` → GitHub Release zip; in-app updater installs over the running `.app`.

## Stack

- SwiftUI app → Pi (`pi --mode rpc` with real sessions) → llama.cpp router (`127.0.0.1:9931`)
- Model list is synced from the router into `~/.pi/agent/models.json`
- Projects / bots: `~/Library/Application Support/CoffeeAndPi/projects.json`
- Chats: `…/chats.json` + Pi sessions under `…/pi-sessions/`
- Per-model knobs / HF download / Auto ctx: see `FEATURES.md` (includes transcript `35f4f953`)
