# TileServer GL - OpenMapTiles Setup

Self-hosted vector tile server with OpenMapTiles styles and custom tile generation.

## Overview

This setup provides a complete self-hosted map tile server using:
- **TileServer GL** - Vector tile server with MapLibre GL rendering
- **OpenMapTiles** - Open-source map styles (OSM + OSM Bright)
- **Planetiler** - Fast OpenStreetMap tile generator

## Directory Structure

```
.
├── setup-styles.sh          # Install map styles and fonts
├── setup-tiles.sh           # Generate MBTiles from OSM data
├── docker-compose.yaml       # TileServer GL container config
├── data/
│   ├── config.json         # TileServer configuration
│   ├── fonts/              # Web fonts (Noto Sans, Roboto, etc.)
│   ├── styles/             # Map styles
│   │   ├── osm/            # OpenMapTiles default style
│   │   └── osm-bright/     # OSM Bright style
│   └── tiles/
│       └── tiles.mbtiles   # Vector tiles (generated)
└── build/                  # Build artifacts (git clones, etc.)
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

Access your tile server at: `http://localhost:8080`

## Advanced Usage

### Custom Java Settings

```bash
# Set custom heap size for tile generation
JAVA_TOOL_OPTIONS="-Xms8G -Xmx8G" ./setup-tiles.sh germany
```

### Update Styles

```bash
# Re-run to get latest styles
./setup-styles.sh
docker compose down && docker compose up -d
```

### Regenerate Tiles for Different Region

```bash
# Switch from Germany to Europe
./setup-tiles.sh europe
docker compose down && docker compose up -d
```

**Note:** Old tiles are automatically replaced (no backup is created due to file size).

## System Requirements

### Hardware

- **RAM:** Minimum 4GB, 8GB+ recommended for larger regions
- **Disk:** Varies by region
  - Germany: ~2-3 GB
  - Europe: ~20-30 GB
  - Planet: ~100+ GB
- **CPU:** Multi-core recommended (used during tile generation)

### Software Dependencies

Automatically installed by scripts:
- `git`
- `docker`
- `docker-compose-plugin`
- `jq`
- `sed`
- `make`
- `wget`
- `openjdk-21-jre`

## Available Styles

### OSM (OpenMapTiles Default)
Complete OpenMapTiles style with detailed rendering for all zoom levels and full feature coverage.

### OSM Bright
Clean, bright color scheme optimized for readability, based on the official OSM Bright style.

Both styles are pre-configured to use local MBTiles data.

## Resources

- [TileServer GL Documentation](https://tileserver.readthedocs.io/)
- [OpenMapTiles](https://openmaptiles.org/)
- [Planetiler](https://github.com/onthegomap/planetiler)
- [Geofabrik Downloads](https://download.geofabrik.de/)

## License

This setup uses open-source components:
- TileServer GL - BSD 2-Clause License
- OpenMapTiles - BSD 3-Clause License
- Planetiler - Apache License 2.0
- Map data © OpenStreetMap contributors - Open Data Commons Open Database-Lizenz (ODbL)
