# Rules file

`~/Library/Application Support/LocoHost/rules.json` is written with defaults on first run, and *Edit Rules…* in the menu opens it. New defaults arrive with upgrades and never remove an entry of yours.

```json
{ "protect": { "names": ["postgres", "redis-server", "epmd", "ollama", "com.docker.backend", "…"],
               "ports": [5173],
               "paths": ["~/Documents/GitHub/always-on"] },
  "ignore":  { "names": ["rapportd", "sharingd", "Spotify", "OneDrive", "…"],
               "devApps": ["Docker", "OrbStack", "Ollama", "Postgres", "LM Studio", "…"] } }
```

## Protect

`protect` keeps a server out of Close Idle by process name, port or folder prefix. *Protect* in a row's submenu adds its port. The defaults cover databases and shared infrastructure: Postgres, MySQL, MariaDB, Redis, Valkey, MongoDB, Memcached, epmd, Ollama, Docker, OrbStack, ClickHouse, Meilisearch, Typesense, MinIO, Mailpit, MailHog, Caddy, nginx, httpd, LM Studio, Tailscale and cloudflared.

## Ignore

`ignore.names` hides a listener from the list. It shows under *Ignored* and is never acted on.

A process inside the bundle of a running app is ignored, unless the app is on `devApps`. That keeps Spotify, AirPlay and OneDrive out of the list, while Docker and Postgres.app still show. Interpreters that ship as an app bundle, such as Python.app, belong to no running app and are listed.

Anything under `/System/`, `/usr/libexec/`, `/usr/sbin/` or `/Library/Apple/` is ignored.
