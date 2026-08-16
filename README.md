# Soumo's Umbrel App Store

A personal [community app store](https://github.com/getumbrel/umbrel-community-app-store)
for [umbrelOS](https://umbrel.com).

## Add this store to your Umbrel

1. Open your Umbrel dashboard.
2. Go to **App Store**, then the three-dot menu, then **Community App Stores**.
3. Paste this repository's URL and click **Add**.

The store and its apps then appear alongside the official app store.

## Apps

| App | Description | Notes |
| --- | --- | --- |
| [OpenAlgo](soumo-openalgo) | Algorithmic trading platform for 35+ Indian brokers | Needs a one-time `.env` bootstrap over SSH — see its [README](soumo-openalgo/README.md) |

## Layout

```
umbrel-app-store.yml          store id and display name
soumo-openalgo/
├── umbrel-app.yml            app manifest
├── docker-compose.yml        service definition
├── bootstrap-env.sh          one-time host-side setup
├── icon.svg                  dashboard icon
└── README.md                 install and operations guide
```

Every app directory name must be prefixed with the store `id` from
`umbrel-app-store.yml`, and must match the `id` inside that app's
`umbrel-app.yml`. Store id here is `soumo`, so apps are `soumo-<name>`.

## Conventions used here

- **Prebuilt images only.** umbrelOS does not build from source, so
  `docker-compose.yml` never carries a `build:` key. Images must be multi-arch
  (`linux/amd64` and `linux/arm64`) to cover both Umbrel Home and Raspberry Pi.
- **`app_proxy` fronts exactly one port.** Any second port an app needs is
  published directly in its compose file, and the reason is written in a
  comment next to it.
- **Persistence goes under `${APP_DATA_DIR}/data/`.** Nothing that matters
  lives inside a container layer.
- **`restart: on-failure`**, not `unless-stopped` — umbrelOS owns start and
  stop.

## License

Packaging in this repository is MIT. Each app remains under its upstream
license: OpenAlgo is AGPL-3.0.
