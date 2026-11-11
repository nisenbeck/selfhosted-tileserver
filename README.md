# TileServer GL - OpenMapTiles Setup

Self-hosted tile server with OpenMapTiles styles, custom tile generation, and nginx caching proxy.

## Overview

This setup provides a complete self-hosted map tile server using:
- **TileServer GL** - Vector tile server with MapLibre GL rendering
- **OpenMapTiles** - Open-source map styles (OSM + OSM Bright)
- **Planetiler** - Fast OpenStreetMap tile generator
- **Nginx Caching Proxy** - Tile cache that stays valid until the data changes

## Architecture
```
Client Request
     ↓
Nginx Cache (Port 8081, localhost only)
     ↓ (cache miss)
TileServer GL (Port 8080, localhost only)
     ↓
MBTiles Database

Init Container → creates cache directory with correct permissions
```

**Cache invalidation:**
- Cached tiles stay valid until the data changes. The cache only reduces the rendering load on TileServer GL.
- TileServer GL loads new data only at a restart. Thus a restart is the moment to clear the cache.
- At each start, `nginx/05-invalidate-cache.sh` calculates a fingerprint of `data/` (path, size and modification time of all files, except `data/cache/`). The script compares it with the stamp file `data/cache/data.fingerprint`. If the values are different, the script moves the cache to `data/cache/trash-*` before nginx starts. A rename is fast, thus nginx starts without delay. A background process deletes the trash while nginx runs. When it ends, nginx logs `unknown process ... exited with code 0`. This is expected.
- The fingerprint includes the MBTiles files, `config.json`, styles, sprites and fonts.
- A restart without a data change (for example, an image update) keeps the cache.
- The script follows symbolic links and uses the size and modification time of the link target. The target must be mounted in `tileserver-cache` too.
- The fingerprint needs no read permission for the files. A directory in `data/` must be readable and executable for uid 101.
- If `data/tiles/` has no `*.mbtiles` file (also a dangling link), a directory is not readable or there is a symbolic link loop, the script does not change the cache and logs a warning or an error. Usually, this is an incorrect mount.

**Start order:**
- `tileserver-cache` starts only when `tileserver-app` is healthy (`/health` returns 200 only after all data is loaded).
- If `tileserver-app` does not become healthy, Compose logs a warning and starts `tileserver-cache` anyway. Cached tiles stay available. nginx does not cache errors.
- `docker compose restart` ignores this order. Use `docker compose up -d --force-recreate` (see [Update Data](#update-data)).

**Security:**
- TileServer GL is only accessible via localhost (Port 8080)
- Nginx cache is only accessible via localhost (Port 8081)
- Nginx proxy validates requests and serves only raster tiles
- All other endpoints are blocked (404)

## Directory Structure
```
.
├── setup-styles.sh           # Install map styles and fonts
├── setup-tiles.sh            # Generate MBTiles from OSM data
├── docker-compose.yaml       # Container orchestration
├── nginx/
│   ├── default.conf.template # Nginx cache configuration
│   └── 05-invalidate-cache.sh # Clears the cache when the data changes
├── tests/
│   └── run.sh                # Tests for the cache (Docker only)
├── data/
│   ├── config.json           # TileServer configuration
│   ├── cache/                # Nginx cache (Docker volume)
│   │   ├── data.fingerprint  # Stamp of the cached data
│   │   ├── tiles/            # Cached tiles
│   │   └── trash-*/          # Old cache, deleted in the background
│   ├── fonts/                # Web fonts (Noto Sans, Roboto, etc.)
│   ├── styles/               # Map styles
│   │   ├── osm/              # OpenMapTiles default style
│   │   └── osm-bright/       # OSM Bright style
│   └── tiles/
│       └── tiles.mbtiles     # Vector tiles (generated)
└── build/                    # Build artifacts (git clones, stage directory, etc.)
```

## Quick Start

### 1. Install Styles and Fonts

```bash
./setup-styles.sh
```

This script will:
- Clone OpenMapTiles and OSM Bright repositories
- Download and build fonts (Noto Sans, Roboto, Open Sans, etc.)
- Build sprite sheets
- Install styles to `data/styles/`
- Configure styles for local MBTiles usage

### 2. Generate Tiles

```bash
# Generate tiles for a specific region
./setup-tiles.sh germany

# Or use auto-detected settings
./setup-tiles.sh europe

# With custom thread count
./setup-tiles.sh germany 8

# To generate planet tiles, at least 32 GB of memory is required
./setup-tiles.sh planet
```

This script will:
- Install Java 21 JRE (if needed)
- Download latest Planetiler release
- Auto-detect optimal RAM and CPU settings
- Download OSM data for specified region
- Generate vector tiles in OpenMapTiles schema
- Deploy to `data/tiles/tiles.mbtiles`

**Available regions:** `germany`, `europe`, `north-america`, `planet`, etc.

See [Geofabrik](https://download.geofabrik.de/) for all available regions.

### 3. Start TileServer

```bash
docker compose up -d
```

Access tiles via the nginx cache at: `http://localhost:8081`
Access the TileServer GL UI at: `http://localhost:8080`

## API Endpoints

### Raster Tiles (via Nginx Cache, Port 8081)
```
GET /styles/{style}/{z}/{x}/{y}.png        # Standard resolution (256px)
GET /styles/{style}/{z}/{x}/{y}@2x.png     # Retina resolution (512px)
GET /styles/{style}/{z}/{x}/{y}@3x.png     # High-DPI resolution (768px)
GET /styles/{style}/{z}/{x}/{y}.webp       # Standard resolution (WebP)
GET /styles/{style}/{z}/{x}/{y}@2x.webp    # Retina resolution (WebP)
GET /styles/{style}/{z}/{x}/{y}@3x.webp    # High-DPI resolution (WebP)
```

**Available styles:** `osm`, `osm-bright`
**Available formats:** `png`, `webp`

**Server-side cache behavior:**
- Successful tiles (200): Valid until the data changes (technical limit 365 days)
- Errors (for example 404 while TileServer GL loads the data): Not cached
- Cache header: `X-Cache-Status` (for example `HIT`, `MISS`, `STALE`, `UPDATING`)

Set these environment variables (for example in a `.env` file next to `docker-compose.yaml`) to limit the disk space:

| Variable | Default | Function |
|---|---|---|
| `CACHE_MAX_SIZE` | `25g` | Maximum cache size. When the cache reaches this size, nginx removes the tiles with the oldest access. |
| `CACHE_MIN_FREE` | `20g` | Minimum free space on the file system. If there is less free space, nginx removes tiles. |
| `CACHE_INACTIVE` | `30d` | nginx removes tiles that no client requested in this period. |

nginx renders a removed tile again on the next request. `CACHE_MAX_SIZE` is a soft limit: the cache can be larger for a short time. If the cache always stays at `CACHE_MAX_SIZE`, increase the value.

**Client-side cache behavior:**
- `Cache-Control: max-age=86400, stale-while-revalidate=604800`
- The browser uses a tile for 1 day. After this, it shows the tile from its cache and asks the server in the background.
- The browser revalidates with the `ETag` (`If-None-Match`). nginx answers from the cache with `304 Not Modified`. The `ETag` depends on the tile contents. Thus it stays the same after the cache is cleared, if the tile did not change.
- nginx removes the `Last-Modified` header. TileServer GL sets it to the render time. Thus it changes when a tile is rendered again, and a revalidation with `If-Modified-Since` would always return the full tile.

### All Other Endpoints

All requests outside the raster tile pattern return `404 Not Found`.

## Advanced Usage

### Custom Java Settings

```bash
# Set custom heap size for tile generation
JAVA_TOOL_OPTIONS="-Xms8G -Xmx8G" ./setup-tiles.sh germany
```

### Update Data

TileServer GL loads new data only at a restart. A restart also clears the cache if the data changed. Always use this command after a change in `data/`:

```bash
docker compose up -d --force-recreate
```

Do not use `docker compose restart`. It does not wait until `tileserver-app` is healthy (see [Architecture](#architecture)).

### Clear the Cache Manually

Some changes are not changes of `data/`, for example an update of the TileServer GL image with a new renderer. In this case, the cache keeps the old tiles until the data changes. To clear the cache, delete the stamp file and recreate the containers:

```bash
docker compose exec tileserver-cache rm /var/cache/nginx/data.fingerprint
docker compose up -d --force-recreate
```

Without a stamp file, the startup script clears the cache.

### Copy a New MBTiles File

The MBTiles file is usually generated on a different machine. Do not copy it directly over the old file, because TileServer GL can read a partly written file. Copy to a temporary name on the same file system, then rename it with `mv`. A rename on the same file system is atomic.

```bash
# On the build machine
scp tiles.mbtiles server:/path/to/selfhosted-tileserver/data/tiles/tiles.mbtiles.tmp

# On the server
mv data/tiles/tiles.mbtiles.tmp data/tiles/tiles.mbtiles
docker compose up -d --force-recreate
```

`rsync` writes to a temporary file and renames it by default. `scp` does not.

### Update Styles

```bash
# Re-run to get latest styles
./setup-styles.sh
docker compose up -d --force-recreate
```

The script builds all files in `build/stage/` first. Then it copies only files with changed content to `data/`. Unchanged files keep their modification time, thus the tile cache stays valid. If no file changed, the script tells you that a restart is not necessary.

### Regenerate Tiles for Different Region

```bash
# Switch from Germany to Europe
./setup-tiles.sh europe
docker compose up -d --force-recreate
```

**Note:** Old tiles are automatically replaced (no backup is created due to file size).

## Nginx Cache Configuration

The nginx caching proxy provides:
- **Server-side tile caching** until the data changes
- **Configurable cache limits** (`CACHE_MAX_SIZE`, `CACHE_MIN_FREE`, `CACHE_INACTIVE`)
- **CORS headers** enabled for cross-origin requests
- **Compression disabled** (PNG/WebP tiles are already compressed)
- **Cache locking** to prevent thundering herd
- **Stale cache serving** during backend errors
- **Client-side caching** with `stale-while-revalidate` and `ETag` revalidation

The cache is stored in `data/cache/`. It persists across container restarts if the data does not change.

The container logs of `tileserver-app` and `tileserver-cache` rotate at 5 files of 100 MB each (`logging` in `docker-compose.yaml`).

### Tests

`tests/run.sh` tests the nginx configuration, the cache invalidation and the cache-related parts of `docker-compose.yaml`. It needs only Docker with the Compose plugin. A small mock replaces TileServer GL. The tests take approximately 2 minutes.

```bash
./tests/run.sh
```

## System Requirements

### Hardware

- **RAM:** Minimum 4GB, 8GB+ recommended for larger regions
- **Disk:** Varies by region
  - Germany: ~2-3 GB
  - Europe: ~20-30 GB
  - Planet: ~100+ GB
  - Tile cache: up to `CACHE_MAX_SIZE` (default 25 GB). nginx keeps `CACHE_MIN_FREE` (default 20 GB) free on the file system.
- **CPU:** Multi-core recommended (used during tile generation)

### Software Dependencies

Install before you start:
- `docker` with the Compose plugin (`docker compose`) 2.20 or later

The setup scripts install missing packages with `apt-get` (Debian/Ubuntu). Thus they need root permissions:
- `setup-styles.sh`: `git`, `jq`, `sed`, `make`
- `setup-tiles.sh`: `curl`, `jq`, `openjdk-21-jre`

## Available Styles

### OSM (OpenMapTiles Default)

Complete OpenMapTiles style with detailed rendering for all zoom levels and full feature coverage.

### OSM Bright

Clean, bright color scheme optimized for readability, based on the official OSM Bright style.

Both styles are pre-configured to use local MBTiles data and are accessible through the nginx cache.

## Performance

- Increase `CACHE_MAX_SIZE` for a larger cache
- Add more RAM to tile generation: `JAVA_TOOL_OPTIONS="-Xmx16G"`
- Use faster storage

## Resources

- [TileServer GL Documentation](https://tileserver.readthedocs.io/)
- [OpenMapTiles](https://openmaptiles.org/)
- [Planetiler](https://github.com/onthegomap/planetiler)
- [Geofabrik Downloads](https://download.geofabrik.de/)
- [Nginx Caching Guide](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cache)

## License

This setup uses open-source components:
- TileServer GL - BSD 2-Clause License
- OpenMapTiles - BSD 3-Clause License
- Planetiler - Apache License 2.0
- Nginx - BSD 2-Clause License
- Map data © OpenStreetMap contributors - Open Data Commons Open Database License (ODbL)
