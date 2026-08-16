# OpenAlgo on umbrelOS

Self-hosted algorithmic trading platform for Indian brokers, packaged for
umbrelOS. Upstream project: <https://github.com/marketcalls/openalgo>

Image: `marketcalls/openalgo:latest` (multi-arch, `linux/amd64` and
`linux/arm64`) — works on both Umbrel Home and Raspberry Pi.

## Install

1. Install **OpenAlgo** from this community app store. It will start and then
   fail its health check. That is expected — see step 2.

2. SSH into your Umbrel and run the bootstrap script once:

   ```bash
   ssh umbrel@umbrel.local
   curl -fsSL https://raw.githubusercontent.com/Soumojit28/umbrel-app-store/main/soumo-openalgo/bootstrap-env.sh -o bootstrap-env.sh
   chmod +x bootstrap-env.sh
   ./bootstrap-env.sh
   ```

   Pass a hostname or IP if `umbrel.local` is not how you reach the box:

   ```bash
   ./bootstrap-env.sh 192.168.1.42
   ```

3. Add your broker credentials:

   ```bash
   sudo nano ~/umbrel/app-data/soumo-openalgo/data/.env
   ```

   Set `BROKER_API_KEY`, `BROKER_API_SECRET`, and `REDIRECT_URL`.

4. Restart OpenAlgo from the Umbrel dashboard, then open
   `http://umbrel.local:5000` and create your account.

### Why step 2 exists

`docker-compose.yml` bind-mounts a single **file**
(`${APP_DATA_DIR}/data/.env` to `/app/.env`). When the source file does not
exist, Docker creates a **directory** at that path instead, and the container
exits because it cannot read its configuration. umbrelOS has no pre-start hook
that could seed the file, so the first run is bootstrapped by hand.

The script also fixes three things that are easy to get wrong:

- **Ownership.** The container runs as `appuser`, pinned to UID/GID 1000. The
  `.env` mount is read-write because OpenAlgo rotates `FERNET_SALT` in place on
  first run; a root-owned file makes that fail and gunicorn restart-loops
  (upstream issues #1394 and #960).
- **Bind addresses.** `FLASK_HOST_IP` and `WEBSOCKET_HOST` default to
  `127.0.0.1`. Inside a container that means the Docker port mapping and
  `app_proxy` have nothing to reach. Both are rewritten to `0.0.0.0`.
- **Secrets.** Fresh `APP_KEY` and `API_KEY_PEPPER` are generated with
  `secrets.token_hex(32)` instead of shipping the well-known sample values.

## Ports

| Port | Exposure | Purpose |
| --- | --- | --- |
| 5000 | via `app_proxy` | Web UI, REST API `/api/v1/`, SocketIO |
| 8765 | published directly | Raw market-data WebSocket proxy |
| 5555 | never published | Internal ZeroMQ tick bus, loopback only |

`app_proxy` fronts one port only, so 8765 is published by the compose file.
It serves `/websocket/test` and Python SDK feed clients. ZeroMQ stays on
loopback — publishing it would leak the raw tick feed.

If port 5000 collides with another Umbrel app, change `port:` in
`umbrel-app.yml` and update `HOST_SERVER` and `CORS_ALLOWED_ORIGINS` in your
`.env` to match.

## Umbrel proxy auth is off

`PROXY_AUTH_ADD: "false"` is set deliberately. OpenAlgo has its own login, and
leaving Umbrel's proxy auth on would bounce webhook callers (TradingView,
ChartInk, Amibroker) before they reach `/api/v1/`.

Consequence: anything on your LAN can reach the OpenAlgo login page. OpenAlgo's
own authentication still applies, but do not port-forward this to the internet
without TLS in front of it.

## Resource tuning

Defaults in `docker-compose.yml` target a 4GB Raspberry Pi. On an 8GB Pi or an
Umbrel Home, raise them:

| Setting | 4GB Pi | 8GB | 16GB+ |
| --- | --- | --- | --- |
| `shm_size` | `256m` | `512m` | `1g` |
| `*_NUM_THREADS` | `2` | `2` | `4` |
| `STRATEGY_MEMORY_LIMIT_MB` | `256` | `512` | `1024` |

The thread caps are not cosmetic — unbounded OpenBLAS/NumPy thread pools
exhaust `RLIMIT_NPROC` inside containers (upstream issue #822).

## Things to know before you trade real money

**SEBI static IP mandate.** Since 1 April 2026, transactional API orders
require a broker-side whitelisted static IP. Home broadband is typically
dynamic, so order placement breaks whenever your ISP rotates the address.
Either get a static IP from your ISP or route broker traffic through a
fixed-IP VPS. Market data and read-only calls are unaffected.

**Session cookies are not marked secure over plain HTTP.** OpenAlgo derives
cookie flags from the `HOST_SERVER` scheme. LAN-only over `http://` is
workable; if you expose the app, terminate TLS and switch `HOST_SERVER` to
`https://` and `WEBSOCKET_URL` to `wss://`.

**Broker callback URLs.** Many brokers only accept a callback they have on
file, and some reject non-HTTPS URLs outright. Check your broker's developer
console before assuming `http://umbrel.local:5000/<broker>/callback` will be
accepted.

**Paper trade first.** The built-in Sandbox engine gives you 1 Crore of virtual
capital against live data with exchange-aligned auto square-off.

## Upgrading

The compose file tracks `marketcalls/openalgo:latest`. To pull a newer build:

```bash
ssh umbrel@umbrel.local
docker pull marketcalls/openalgo:latest
```

Then restart the app from the dashboard. Database migrations
(`upgrade/migrate_all.py`) run automatically on container start.

To make the Umbrel dashboard show an update, bump `version:` in
`umbrel-app.yml` and push.

## Backup

Everything that matters lives in `~/umbrel/app-data/soumo-openalgo/data`:

```
.env          configuration and broker credentials
db/           SQLite databases (main, logs, latency, health, sandbox)
strategies/   your Python strategy scripts
keys/         API keys and certificates
log/          application and strategy logs
```

Back up `.env` and `db/` together. `API_KEY_PEPPER` in `.env` is the KDF input
for every encrypted broker token and password hash in `db/` — restoring one
without the other leaves you with unreadable data.
