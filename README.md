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

| Service | Image | Port | Job |
|---|---|---|---|
| `osm` | `overv/openstreetmap-tile-server:2.3.0` | `0.0.0.0:8080` | raster PNG tiles |
| `nominatim` | `mediagis/nominatim:5.1-2025-07-29T07-58` | `0.0.0.0:8088` | forward + reverse geocoding |
| `osrm` | `ghcr.io/project-osrm/osrm-backend:v5.27.1` | `0.0.0.0:5000` | car routing (MLD) |
| `osm-import` | tile-server image | — | one-off PostGIS import |
| `osrm-prepare` | OSRM image | — | one-off graph build |

Tiles are public (browsers load them directly). Nominatim and OSRM are bound to
loopback — see [Network exposure](#network-exposure) before using them from a
browser.

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

# 2. A password for the Nominatim database role (see warning below)
echo "NOMINATIM_PASSWORD=$(openssl rand -hex 16)" > .env
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

```bash
# Tile for central Tehran (z12) — expect HTTP 200
curl -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:8080/tile/12/2632/1614.png

# CORS header, needed for cross-origin tile loading
curl -sI http://127.0.0.1:8080/tile/12/2632/1614.png | grep -i access-control
# → Access-Control-Allow-Origin: *

# Geocoder health
curl http://127.0.0.1:8088/status
# → OK

# Forward geocoding, Persian script
curl "http://127.0.0.1:8088/search?q=$(python3 -c 'import urllib.parse;print(urllib.parse.quote("تهران"))')&format=json&limit=1"

# Reverse geocoding, central Tehran
curl "http://127.0.0.1:8088/reverse?lat=36.558188&lon=48.716125&format=json"

# Routing — expect {"code":"Ok",...}
curl "http://127.0.0.1:5000/route/v1/driving/48.716125,36.558188;48.730000,36.570000?overview=false"
```

On a successful import of the Iran extract the tile database holds roughly:
**822k points · 2.4M lines · 219k roads · 897k polygons**.

---

## Connecting h-dashboard

In the h-dashboard `.env`:

```dotenv
TILE_SERVER_SCHEME=http
TILE_SERVER_IP=<this-host>
TILE_SERVER_PORT=8080
TILE_URL_TEMPLATE=http://<this-host>:8080/tile/{z}/{x}/{y}.png
```

Then read [Network exposure](#network-exposure) before enabling search and
routing.

---

## Network exposure

All three services bind to `0.0.0.0` and are reachable from any host that can
route to this machine.

| Port | Service | Purpose |
|---|---|---|
| `8080` | tiles | loaded by every browser |
| `8088` | Nominatim | search + reverse geocoding |
| `5000` | OSRM | routing |

**Why not loopback:** h-dashboard calls Nominatim and OSRM directly from browser
JavaScript (`resources/views/livewire/maps/route2.blade.php` does
`axios.get()` against the geocoding URL and points Leaflet-Routing at the
routing URL). `127.0.0.1` inside a browser resolves to **the user's own
machine**, so a loopback binding would leave search and routing working only on
the server itself. Bind to a routable address instead.

```dotenv
GEOCODING_SERVER_IP=<this-host>
GEOCODING_SERVER_PORT=8088
ROUTING_SERVER_IP=<this-host>
ROUTING_SERVER_PORT=5000
```

### ⚠ Rate-limit Nominatim before real traffic

This is the cost of a public bind, and it is not optional in good conscience.
[Nominatim's usage policy](https://operations.osmfoundation.org/policies/nominatim/)
allows an **absolute maximum of 1 request per second** and requires an
identifying `User-Agent`. The `mediagis/nominatim` image sends no `User-Agent`
and enforces no rate limit of its own.

Unthrottled, one page load per user is enough to get the server
blocked. Put a reverse proxy in front of `:8088` that caps at 1 req/s, adds a
`User-Agent`, and restricts by IP or key. OSRM has no equivalent policy, but
`--algorithm mld` will happily consume all available RAM under load, so cap it
too.

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