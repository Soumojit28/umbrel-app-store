# OpenAlgo on umbrelOS

Self-hosted algorithmic trading platform for Indian brokers, packaged for
umbrelOS. Upstream project: <https://github.com/marketcalls/openalgo>

Image: `marketcalls/openalgo:2d8edfd` — pinned by commit, multi-arch
(`linux/amd64` and `linux/arm64`), so it works on both Umbrel Home and
Raspberry Pi. Upstream publishes no semver tags, only `latest` and short-SHA
tags; `2d8edfd` is release 2.0.2.0 and is digest-identical to the `latest`
that was current when this was packaged.

## Install

1. If you reach your Umbrel at something other than `umbrel.local`, edit
   `OA_HOSTNAME` in `docker-compose.yml` first. Otherwise skip this.

2. Install **OpenAlgo** from this community app store. No SSH needed.

3. Open `http://umbrel.local:5000` and create your account.

4. Add broker credentials in the OpenAlgo UI, or on disk:

   ```bash
   sudo nano ~/umbrel/app-data/soumo-openalgo/data/.env
   ```

   Set `BROKER_API_KEY`, `BROKER_API_SECRET`, and `REDIRECT_URL`, then restart
   the app from the dashboard.

First boot takes a few minutes: database migrations run before gunicorn binds,
which is why the health check allows a 180 second start period.

### What the init service does

`docker-compose.yml` bind-mounts a single **file**
(`${APP_DATA_DIR}/data/.env` to `/app/.env`). When the source file does not
exist, Docker creates a **directory** at that path instead, the container exits
because it cannot read its configuration, and umbrelOS reports the install as
failed. umbrelOS has no pre-start hook, so a one-shot `init` service runs to
completion first (`depends_on: service_completed_successfully`) and guarantees
the file exists.

It runs from the same image, so there is no extra pull, and it reads
`.sample.env` from inside the image rather than the network. It fixes three
things that are easy to get wrong:

- **Secrets.** Fresh `APP_KEY` and `API_KEY_PEPPER` from
  `secrets.token_hex(32)`, instead of the well-known sample values.
- **Bind addresses.** `FLASK_HOST_IP` and `WEBSOCKET_HOST` default to
  `127.0.0.1`. Inside a container that means the Docker port map and
  `app_proxy` have nothing to reach. Both become `0.0.0.0`. `ZMQ_HOST` is
  deliberately left on loopback.
- **Ownership.** The app runs as `appuser`, pinned to UID/GID 1000. The `.env`
  mount is read-write because OpenAlgo rotates `FERNET_SALT` in place; a
  root-owned file makes that fail and gunicorn restart-loops (upstream issues
  #1394 and #960).

In-place rewriting of a bind-mounted `.env` is supported upstream —
`utils/env_check.py:344` detects the bind mount and skips the temp-file plus
rename pattern, which would otherwise fail with `EXDEV` across filesystems.

## Troubleshooting

Everything below runs on the Umbrel box over `ssh umbrel@umbrel.local`.

**App will not install or immediately shows as stopped**

```bash
docker ps -a --filter name=soumo-openalgo
docker logs soumo-openalgo_init_1
docker logs soumo-openalgo_web_1 --tail 100
```

`init` should exit 0 and print `[init] done`. If it never ran, your umbrelOS
is too old for `depends_on.condition`; run `bootstrap-env.sh` manually instead.

**Check the config actually landed**

```bash
ls -la ~/umbrel/app-data/soumo-openalgo/data/.env
```

Must be a **file**, owned by `1000:1000`, mode `600`. If it is a directory,
the init service did not run — delete it and run `bootstrap-env.sh`.

**Store added but no app tile**

```bash
ls ~/umbrel/app-stores/
```

Look for a directory derived from this repo URL containing `soumo-openalgo/`.
If the clone is stale after a push, remove and re-add the store in the UI.

**Port 5000 already taken by another app**

Change `port:` in `umbrel-app.yml`, then update `HOST_SERVER` and
`CORS_ALLOWED_ORIGINS` in `.env` to match.

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

The image is pinned by commit SHA, so nothing moves under you. Upstream
publishes no semver tags — only `latest` and short-SHA tags — so an upgrade
means picking a newer SHA deliberately.

1. Find the current tag:

   ```bash
   curl -fsSL "https://hub.docker.com/v2/repositories/marketcalls/openalgo/tags?page_size=5&ordering=last_updated"
   ```

2. Update **both** `image:` lines in `docker-compose.yml` — `init` and `web`
   must stay on the same tag.
3. Bump `version:` in `umbrel-app.yml` so the dashboard offers the update.
4. Commit and push, then update the app from the Umbrel UI.

Database migrations (`upgrade/migrate_all.py`) run automatically on container
start, so no manual migration step is needed.

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
