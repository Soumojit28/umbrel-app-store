#!/usr/bin/env bash
#
# OpenAlgo on umbrelOS - .env repair and reconfigure tool.
#
# NOT required for a normal install. The `init` service in docker-compose.yml
# seeds .env automatically before the app starts. Reach for this script only
# when:
#
#   - you need to change the hostname baked into the browser-facing URLs
#     (HOST_SERVER, WEBSOCKET_URL, CORS_ALLOWED_ORIGINS, REDIRECT_URL),
#     e.g. you reach your Umbrel by IP instead of umbrel.local
#   - the config got into a bad state and you want a clean one
#   - you are recovering an install that predates the init service
#
# Run it ON THE UMBREL BOX: ssh umbrel@umbrel.local
#
# Safe to re-run: an existing .env file is left untouched unless --force.
# --force regenerates APP_KEY and API_KEY_PEPPER, which invalidates every
# stored password hash and encrypted broker token. Back up first.
#
# Usage:
#   ./bootstrap-env.sh                    # host defaults to umbrel.local
#   ./bootstrap-env.sh 192.168.1.42       # use an IP instead
#   ./bootstrap-env.sh umbrel.local --force
#
set -euo pipefail

APP_ID="soumo-openalgo"
UMBREL_ROOT="${UMBREL_ROOT:-$HOME/umbrel}"
APP_DATA_DIR="$UMBREL_ROOT/app-data/$APP_ID"
DATA_DIR="$APP_DATA_DIR/data"
ENV_FILE="$DATA_DIR/.env"
SAMPLE_URL="https://raw.githubusercontent.com/marketcalls/openalgo/main/.sample.env"

HOST_NAME="umbrel.local"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *) HOST_NAME="$arg" ;;
    esac
done

WEB_PORT=5000
WS_PORT=8765

info()  { echo "[bootstrap] $*"; }
fail()  { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

[ -d "$UMBREL_ROOT" ] || fail "Umbrel root not found at $UMBREL_ROOT. Set UMBREL_ROOT and retry."
[ -d "$APP_DATA_DIR" ] || fail "App data dir not found at $APP_DATA_DIR. Install the app from the Umbrel app store first."

# ---------------------------------------------------------------------------
# 1. Clear the stray directory Docker creates for a missing bind-mount source
# ---------------------------------------------------------------------------
if [ -d "$ENV_FILE" ]; then
    info "Removing the empty directory Docker created at $ENV_FILE"
    sudo rm -rf "$ENV_FILE"
fi

if [ -f "$ENV_FILE" ] && [ "$FORCE" -eq 0 ]; then
    info "$ENV_FILE already exists. Nothing to do."
    info "Re-run with --force to overwrite it (this regenerates APP_KEY and"
    info "API_KEY_PEPPER, which invalidates existing sessions AND every stored"
    info "password hash and encrypted broker token)."
    exit 0
fi

if [ -f "$ENV_FILE" ] && [ "$FORCE" -eq 1 ]; then
    BACKUP="$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
    info "--force given. Backing up existing .env to $BACKUP"
    sudo cp -a "$ENV_FILE" "$BACKUP"
fi

sudo mkdir -p "$DATA_DIR"

# ---------------------------------------------------------------------------
# 2. Fetch the upstream sample config
# ---------------------------------------------------------------------------
TMP_ENV="$(mktemp)"
trap 'rm -f "$TMP_ENV"' EXIT

info "Downloading .sample.env from upstream"
curl -fsSL "$SAMPLE_URL" -o "$TMP_ENV" || fail "Could not download $SAMPLE_URL"

# ---------------------------------------------------------------------------
# 3. Generate secrets and rewrite the network bindings
# ---------------------------------------------------------------------------
gen_secret() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import secrets; print(secrets.token_hex(32))"
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        fail "Need python3 or openssl to generate secrets."
    fi
}

APP_KEY="$(gen_secret)"
API_KEY_PEPPER="$(gen_secret)"

info "Generated fresh APP_KEY and API_KEY_PEPPER"

sed -i \
    -e "s|OPENALGO_PLACEHOLDER_APP_KEY_REGENERATE_BEFORE_USE|$APP_KEY|g" \
    -e "s|OPENALGO_PLACEHOLDER_API_KEY_PEPPER_REGENERATE_BEFORE_USE|$API_KEY_PEPPER|g" \
    "$TMP_ENV"

# FLASK_HOST_IP and WEBSOCKET_HOST must bind 0.0.0.0 INSIDE the container.
# On loopback the Docker port mapping and the app_proxy have nothing to reach.
sed -i \
    -e "s|FLASK_HOST_IP='127.0.0.1'|FLASK_HOST_IP='0.0.0.0'|g" \
    -e "s|WEBSOCKET_HOST='127.0.0.1'|WEBSOCKET_HOST='0.0.0.0'|g" \
    "$TMP_ENV"

# ZMQ_HOST is deliberately NOT rewritten. The broker adapters and the
# WebSocket proxy run in the same container, so the tick bus stays on
# loopback and is never reachable from the LAN.

# Browser-facing URLs.
sed -i \
    -e "s|HOST_SERVER = 'http://127.0.0.1:5000'|HOST_SERVER = 'http://$HOST_NAME:$WEB_PORT'|g" \
    -e "s|WEBSOCKET_URL='ws://127.0.0.1:8765'|WEBSOCKET_URL='ws://$HOST_NAME:$WS_PORT'|g" \
    -e "s|CORS_ALLOWED_ORIGINS = 'http://127.0.0.1:5000'|CORS_ALLOWED_ORIGINS = 'http://$HOST_NAME:$WEB_PORT'|g" \
    "$TMP_ENV"

# Point the broker callback at this host. The <broker> placeholder is left in
# place - you replace it with your broker's slug (dhan, zerodha, ...) and
# register the resulting URL in the broker's developer console.
sed -i \
    -e "s|REDIRECT_URL = 'http://127.0.0.1:5000/<broker>/callback'|REDIRECT_URL = 'http://$HOST_NAME:$WEB_PORT/<broker>/callback'|g" \
    "$TMP_ENV"

# ---------------------------------------------------------------------------
# 4. Install with the ownership the container needs
# ---------------------------------------------------------------------------
# The container runs as appuser, pinned to UID/GID 1000. The .env mount is
# read-write because OpenAlgo rotates FERNET_SALT in place on first run; a
# root-owned file makes that fail and gunicorn restart-loops.
# See marketcalls/openalgo#1394 and #960.
sudo cp "$TMP_ENV" "$ENV_FILE"
sudo chown 1000:1000 "$ENV_FILE"
sudo chmod 600 "$ENV_FILE"

# Same UID for the persisted data directories.
for d in db log strategies keys tmp; do
    sudo mkdir -p "$DATA_DIR/$d"
    sudo chown -R 1000:1000 "$DATA_DIR/$d"
done

info "Wrote $ENV_FILE"
echo
echo "Next steps:"
echo
echo "  1. Add your broker credentials:"
echo "       sudo nano $ENV_FILE"
echo
echo "     Set BROKER_API_KEY, BROKER_API_SECRET, and REDIRECT_URL."
echo "     REDIRECT_URL must be http://$HOST_NAME:$WEB_PORT/<broker>/callback"
echo "     and must be registered verbatim in your broker's developer console."
echo
echo "  2. Restart OpenAlgo from the Umbrel dashboard."
echo
echo "  3. Open http://$HOST_NAME:$WEB_PORT and create your account."
echo
