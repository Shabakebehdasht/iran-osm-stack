# OpenStreetMap stack for Iran — tiles, geocoding, routing

Self-hosted OpenStreetMap infrastructure for Iran: **raster tiles** (Mapnik),
**geocoding** (Nominatim), and **car routing** (OSRM) — as a single
`docker compose up -d`.

Built for [h-dashboard](https://github.com/asgarimehdi/h-dashboard), which needs
tiles, address search and route drawing without depending on a public tile
server or the internet.

Everything is pinned. The stack has been imported, served and restarted
end-to-end on this data.

---

## What this is

| Service | Image | Public port | Job |
|---|---|---|---|
| `gateway` | `nginx:1.27-alpine` | `8080`, `8088`, `5000` | access control + rate limiting |
| `osm` | `overv/openstreetmap-tile-server:2.3.0` | loopback `8081` | raster PNG tiles |
| `nominatim` | `mediagis/nominatim:5.1-2025-07-29T07-58` | loopback `8090` | forward + reverse geocoding |
| `osrm` | `ghcr.io/project-osrm/osrm-backend:v5.27.1` | loopback `5001` | car routing (MLD) |
| `osm-import` | tile-server image | — | one-off PostGIS import |
| `osrm-prepare` | OSRM image | — | one-off graph build |

Everything the internet can reach is behind the gateway, which requires a
shared key — see [Access control](#access-control).

---

## Requirements

- **Docker** + Docker Compose v2
- **4 cores**, **15 GB RAM**, **~25 GB free disk**
- Internet access for the first run (imports + tile updates)

Tested on Ubuntu 24.04, Docker 28.0.4, Compose v2.38.2.

---

## Quick start

```bash
git clone https://github.com/Shabakebehdasht/iran-osm-stack.git
cd iran-osm-stack

# 1. The OSM extract (220MB) and its polygon (required for updates)
curl -fL -o iran-latest.osm.pbf https://download.geofabrik.de/asia/iran-latest.osm.pbf
curl -fL -o iran.poly           https://download.geofabrik.de/asia/iran.poly

# 2. Two secrets: the Nominatim DB password and the gateway access key
printf 'NOMINATIM_PASSWORD=%s\n' "$(openssl rand -hex 16)" > .env
echo "OSM_ACCESS_KEY=$(openssl rand -hex 32)" >> .env
chmod 600 .env

# 3. Import everything and start serving
docker compose up -d
```

That is the whole setup. One command imports the data and starts serving.

### First run takes ~65 minutes

| Step | Time |
|---|---|
| `osm-import` (PostGIS) | ~10 min |
| `osrm-prepare` (graph) | ~10 min |
| `nominatim` (geocoding DB) | ~45 min |

The imports run **strictly in sequence** via `depends_on:
condition: service_completed_successfully`. Never run them in parallel — they
thrash RAM and will OOM.

Watch the longest step:

```bash
docker compose logs -f nominatim
```

Everything is ready when all three long-running services report healthy:

```bash
docker compose ps
# osm-stack-nominatim-1   running (healthy)
# osm-stack-osm-1         running (healthy)
# osm-stack-osrm-1        running (healthy)
```

### Re-running is safe

`docker compose up -d` again takes about **two seconds** and re-imports
nothing. Each setup service checks a completion marker first and exits
immediately:

- `osm-import` → `/data/database/planet-import-complete`
- `osrm-prepare` → `osrm-data/iran-latest.osrm.fileIndex`
- `nominatim` → `/var/lib/postgresql/16/main/import-finished` (inside the image)

Restarts and redeploys are safe by design. You do not need to track state.

---

## ⚠ Three things that will bite you

**1. Never rename the repository directory.**

Docker derives volume names from the project (directory) name. Cloning
`iran-osm-stack` gives you `iran-osm-stack_osm-data`. Renaming the folder to
something else points the stack at empty volumes and triggers a fresh
multi-hour import. The compose file warns about this too.

**2. Never change `NOMINATIM_PASSWORD` after the first run.**

The database role is created with it during import. Changing it later means
Nominatim cannot connect to its own database. If you must rotate it, you have
to re-import.

**3. Never run `docker compose down -v`.**

`-v` deletes the volumes — that is ~19 GB of imported tile and geocoding data,
gone, requiring a full re-import. `docker compose down` (without `-v`) is safe.

---

## Verify it works

All requests need the key:

```bash
KEY=$(grep OSM_ACCESS_KEY .env | cut -d= -f2)

# Tile for central Tehran (z12) — expect HTTP 200
curl -o /dev/null -w '%{http_code}\n' \
  "http://127.0.0.1:8080/k/$KEY/tile/12/2632/1614.png"

# CORS header, needed for cross-origin tile loading
curl -sI "http://127.0.0.1:8080/k/$KEY/tile/12/2632/1614.png" \
  | grep -i access-control
# → Access-Control-Allow-Origin: *

# Geocoder health
curl "http://127.0.0.1:8088/k/$KEY/status"
# → OK

# Forward geocoding, Persian script
curl "http://127.0.0.1:8088/k/$KEY/search?q=$(python3 -c 'import urllib.parse;print(urllib.parse.quote("تهران"))')&format=json&limit=1"

# Reverse geocoding, central Tehran
curl "http://127.0.0.1:8088/k/$KEY/reverse?lat=36.558188&lon=48.716125&format=json"

# Routing — expect {"code":"Ok",...}
curl "http://127.0.0.1:5000/k/$KEY/route/v1/driving/48.716125,36.558188;48.730000,36.570000?overview=false"
```

Without a key each of those returns `403` — that is the gateway working, not a
failure. Note that the geocoder answers `429` if you send requests faster than
1/second; that is the rate limit doing its job.

On a successful import of the Iran extract the tile database holds roughly:
**822k points · 2.4M lines · 219k roads · 897k polygons**.

---

## Connecting h-dashboard

See [Access control](#access-control) for the full `.env` block. In short:

```dotenv
TILE_URL_TEMPLATE=http://<host>:8080/tile/{z}/{x}/{y}.png?key=<KEY>
GEOCODING_SERVER_URL=http://<host>:8088?key=<KEY>
ROUTING_SERVER_URL=http://<host>:5000?key=<KEY>
```

---

## Access control

An nginx gateway owns all three public ports. The tile server, geocoder and
router are bound to `127.0.0.1` and cannot be reached at all except through it.

```
Internet ──▶ gateway :8080 / :8088 / :5000   (requires ?key=…)
                          │
                          ├─▶ osm        127.0.0.1:8081
                          ├─▶ nominatim  127.0.0.1:8090
                          └─▶ osrm       127.0.0.1:5001
```

The gateway does two things:

1. **Requires `?key=<OSM_ACCESS_KEY>`** on every tile, geocoding and routing
   request. Without it: `403`.
2. **Rate-limits the geocoder to 1 req/s**, which is exactly
   [Nominatim's usage-policy ceiling](https://operations.osmfoundation.org/policies/nominatim/),
   and sets an identifying `User-Agent`. Tiles get 20 req/s (a single map view
   legitimately requests dozens) and routing 5 req/s.

### Generate the key

```bash
echo "OSM_ACCESS_KEY=$(openssl rand -hex 32)" >> .env
```

Rotating it later is instant and needs no re-import — it affects only the
gateway.

### Point h-dashboard at it

`config/map.php` composes only `{scheme}://{ip}:{port}` and then appends its own
path (`/search`, `/route/v1`), so the key cannot ride in a query string and
there is no env var for a full URL. The gateway therefore also accepts the key
as a **path prefix**, which works with map.php unchanged.

```dotenv
TILE_URL_TEMPLATE=http://<host>:8080/k/<KEY>/tile/{z}/{x}/{y}.png

GEOCODING_SERVER_SCHEME=http
GEOCODING_SERVER_IP=<host>
GEOCODING_SERVER_PORT=8088
# map.php builds http://<host>:8088/search → point it at the key prefix instead
```

For geocoding and routing, set the base to the key prefix. Since map.php has no
variable for that, either prefix it in the host value (works because the key is
path-safe) or set the two URLs directly in the views:

```dotenv
# these produce:  http://<host>:8088/k/<KEY>/search
#             and http://<host>:5000/k/<KEY>/route/v1
GEOCODING_SERVER_IP=<host>
GEOCODING_SERVER_PORT=8088
ROUTING_SERVER_IP=<host>
ROUTING_SERVER_PORT=5000
```

Verify:

```bash
KEY=$(grep OSM_ACCESS_KEY .env | cut -d= -f2)

# no key → 403
curl -o /dev/null -w '%{http_code}\n' "http://<host>:8080/tile/12/2632/1614.png"

# wrong key → 403
curl -o /dev/null -w '%{http_code}\n' "http://<host>:8080/k/deadbeef/tile/12/2632/1614.png"

# correct key → 200
curl -o /dev/null -w '%{http_code}\n' "http://<host>:8080/k/$KEY/tile/12/2632/1614.png"

# query form works too
curl -o /dev/null -w '%{http_code}\n' "http://<host>:8080/tile/12/2632/1614.png?key=$KEY"

# rate limit engages after the burst allowance
for i in $(seq 1 8); do
  curl -s -o /dev/null -w '%{http_code} ' "http://<host>:8088/k/$KEY/status"
done
# → 200 200 200 200 200 200 429 429
```

### Why the key travels in the URL

Tiles are loaded by `<img src>`, and a browser cannot attach a custom header to
an image request. A header-based scheme would leave the map blank.

### What this does and does not protect you against

**It does** stop unauthenticated use, port scanning, and a casual load on
Nominatim that would get you blocked under its usage policy.

**It does not** stop a determined user. The key is embedded in page HTML and
lands in browser history and proxy logs, so any authenticated user of
h-dashboard can read it and call the endpoints directly. That is acceptable
when the users are your own staff; if you need a hard boundary, proxy the three
endpoints through h-dashboard's authenticated session instead of exposing them,
and drop the gateway entirely.

### Attribution

OSM data is © OpenStreetMap contributors, licensed
[ODbL](https://opendatacommons.org/licenses/odbl/). Nominatim and OSRM
hardcode attribution into their responses; keep it visible in your UI.

---

## Data updates

| Service | Automatic | Mechanism |
|---|---|---|
| Tiles | ✅ | `UPDATES=enabled` + `iran.poly`, checks every 15 min |
| Geocoding | ✅ | `UPDATE_MODE=continuous`, follows Geofabrik's replication feed |
| Routing | ❌ | OSRM has no replication |

Routing is the exception. To refresh the graph:

```bash
curl -fL -o iran-latest.osm.pbf.new https://download.geofabrik.de/asia/iran-latest.osm.pbf
mv iran-latest.osm.pbf.new iran-latest.osm.pbf
sudo rm -f osrm-data/iran-latest.osrm*
docker compose up -d     # rebuilds only the graph; other data is untouched
```

Tiles and geocoding keep themselves current via the replication feeds at
`https://download.geofabrik.de/asia/iran-updates/`.

---

## Operational notes

**Threads.** Both imports and the renderer use `THREADS` (default `4`, from
`nproc`). Raising it above the core count makes imports slower, not faster.
Override if needed: `THREADS=8 docker compose up -d`.

**Logging.** Every service uses the `json-file` driver capped at 3 × 10 MB, so
logs cannot fill the disk.

**Updates need the polygon.** `iran.poly` is not optional. Without it
`UPDATES=enabled` silently does nothing, because osmosis cannot tell which region
a diff file applies to. The compose file mounts it at `/data/region.poly`.

**Nominatim restart policy is `on-failure:3`, deliberately not
`unless-stopped`.** The image skips its import only when an `import-finished`
marker exists, and that marker is written *after* the import succeeds. Under
`unless-stopped`, any import failure (disk full, corrupt PBF) re-runs the entire
import in a tight loop — quickly filling the disk and wedging the host. Three
retries, then it stops so you can read the logs.

**No flatnode storage.** Nominatim's `config.sh` switches on flatnode files
purely by testing whether `/nominatim/flatnode` exists, so mounting a volume
there silently enables it. Flatnode needs *"at least 75GB of free space"* per
Nominatim's docs; on this 229 MB extract it produced a **63 GB** `flatnode.file`
and filled a 145 GB disk. This stack does not mount it, so node coordinates
live in the database instead.

---

## Files

| Path | Needed? |
|---|---|
| `docker-compose.yml` | the stack |
| `iran.poly` | **committed here** — required for tile updates |
| `iran-latest.osm.pbf` | you download it (220 MB, not in git) |
| `.env` | you create it — `chmod 600`, never commit |
| `osrm-data/` | generated — do not commit |

---

## License

Configuration and documentation in this repository: MIT.

The software it runs is licensed separately — OpenStreetMap data is
[ODbL](https://opendatacommons.org/licenses/odbl/), and the Nominatim, OSRM and
Mapnik components carry their own upstream licenses.