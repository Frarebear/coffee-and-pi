#!/usr/bin/env bash
# ponytail: install Pi + llama.cpp + llama-router for Coffee & Pi (new Mac)
# Never deletes models/auth — only creates missing pieces.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
HOME_DIR="${HOME}"

echo "==> Pi"
if ! command -v pi >/dev/null 2>&1; then
  mkdir -p "$HOME_DIR/.npm-global"
  npm install -g @earendil-works/pi-coding-agent --prefix "$HOME_DIR/.npm-global"
else
  echo "    pi already on PATH: $(command -v pi)"
fi

echo "==> llama.cpp"
if ! command -v llama >/dev/null 2>&1; then
  curl -LsSf https://llama.app/install.sh | sh
else
  echo "    llama already on PATH: $(command -v llama)"
fi

echo "==> llama-router"
mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/models"
ROUTER="$HOME_DIR/.local/bin/llama-router"
cat > "$ROUTER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
PRESET="${LLAMA_MODELS_PRESET:-$HOME/models/presets.ini}"
HOST="${LLAMA_HOST:-127.0.0.1}"
PORT="${LLAMA_PORT:-9931}"
MODELS_MAX="${LLAMA_MODELS_MAX:-2}"
args=(llama serve --host "$HOST" --port "$PORT" --models-preset "$PRESET" --no-models-autoload --models-max "$MODELS_MAX" -ngl all)
[[ -n "${LLAMA_MODELS_DIR:-}" ]] && args+=(--models-dir "$LLAMA_MODELS_DIR")
args+=("$@")
exec "${args[@]}"
EOF
chmod +x "$ROUTER"

if [[ ! -f "$HOME_DIR/models/presets.ini" ]]; then
  cat > "$HOME_DIR/models/presets.ini" <<'EOF'
# Coffee & Pi model presets — download models from the app or add GGUF paths.
EOF
fi

echo "==> Pi llama.cpp auth"
mkdir -p "$HOME_DIR/.pi/agent"
AUTH="$HOME_DIR/.pi/agent/auth.json"
python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.pi/agent/auth.json")
try:
    with open(path) as f:
        auth = json.load(f)
except Exception:
    auth = {}
auth.setdefault("llama.cpp", {
    "type": "api_key",
    "key": "local",
    "env": {"LLAMA_BASE_URL": "http://127.0.0.1:9931"},
})
with open(path, "w") as f:
    json.dump(auth, f, indent=2, sort_keys=True)
    f.write("\n")
print("    wrote", path)
PY

echo "Done. Optional MLX: brew install mlx-lm"
echo "Then open Coffee & Pi — Settings → Onboarding to replay the wizard."
