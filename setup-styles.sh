#!/bin/bash
set -euo pipefail

#==============================================================================
# OpenMapTiles Style Setup Script
#
# This script automates the setup of OpenMapTiles styles for tileserver-gl:
# - Clones/updates OpenMapTiles repository to ./build/
# - Downloads fonts and builds sprites
# - Copies everything to ./data/
# - Fixes style.json for local usage
# - Sets up OSM Bright style
#
# NOTE: This script is ONLY needed for updating styles/fonts.
#       For normal tileserver operation, you do NOT need to run this.
#
# Usage: Run from tileserver-gl directory (where docker-compose.yaml is)
#==============================================================================

# Get script directory and set paths relative to it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DATA_DIR="$SCRIPT_DIR/data"
OPENMAPTILES_DIR="$BUILD_DIR/openmaptiles"
OSM_BRIGHT_DIR="$BUILD_DIR/osm-bright-gl-style"

# Repository URLs
OPENMAPTILES_REPO="https://github.com/openmaptiles/openmaptiles.git"
OSM_BRIGHT_REPO="https://github.com/openmaptiles/osm-bright-gl-style.git"
OPENMAPTILES_BRANCH="${OPENMAPTILES_BRANCH:-master}"

# Logging helpers
log_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# Cleanup on exit
cleanup() {
    local exit_code=$?
    if [ -n "${TMP_FILE:-}" ] && [ -f "$TMP_FILE" ]; then
        rm -f "$TMP_FILE"
    fi
    if [ $exit_code -ne 0 ]; then
        log_error "Script failed with exit code $exit_code"
    fi
}
trap cleanup EXIT

#==============================================================================
# Initial Warning
#==============================================================================

show_warning() {
    echo ""
    log_warn "╔════════════════════════════════════════════════════════════════╗"
    log_warn "║                        IMPORTANT NOTICE                        ║"
    log_warn "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    log_warn "This script is ONLY needed if you want to UPDATE styles or fonts."
    log_warn "For normal tileserver operation, you do NOT need to run this!"
    echo ""
    log_warn "This script will:"
    log_warn "  - Clone OpenMapTiles repositories"
    log_warn "  - Download fonts (~100MB+)"
    log_warn "  - Build sprites and styles"
    log_warn "  - Update data/styles/ and data/fonts/"
    echo ""
    log_info "Continue? (y/N) [10s timeout, default: N]"

    if read -t 10 -n 1 -r; then
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted by user"
            exit 0
        fi
    else
        echo
        log_info "Timeout - aborting"
        exit 0
    fi
    echo ""
}

#==============================================================================
# Dependency Checks
#==============================================================================

check_dependencies() {
    log_info "Checking dependencies..."

    local missing=()

    # Check all dependencies
    for cmd in git jq sed make; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    # Install missing dependencies
    if [ ${#missing[@]} -gt 0 ]; then
        log_info "Installing missing dependencies: ${missing[*]}"

        if ! apt-get update; then
            log_error "apt-get update failed"
            exit 1
        fi

        if ! apt-get install -y "${missing[@]}"; then
            log_error "Failed to install dependencies: ${missing[*]}"
            exit 1
        fi

        log_info "✓ Dependencies installed: ${missing[*]}"
    else
        log_info "✓ All dependencies present"
    fi
}

check_docker() {
    log_info "Checking Docker..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        log_error "Please install Docker before running this script"
        log_error "See: https://docs.docker.com/engine/install/"
        exit 1
    fi

    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose V2 not available"
        log_error "Please install Docker Compose plugin"
        log_error "Install with: apt-get install -y docker-compose-plugin"
        exit 1
    fi

    log_info "✓ Docker and Docker Compose available"
}

verify_directories() {
    log_info "Verifying directory structure..."

    if [ ! -f "$SCRIPT_DIR/docker-compose.yaml" ]; then
        log_error "docker-compose.yaml not found in $SCRIPT_DIR"
        log_error "Please run this script from the tileserver-gl directory"
        exit 1
    fi

    # Create build and data directories if they don't exist
    mkdir -p "$BUILD_DIR"
    mkdir -p "$DATA_DIR"

    log_info "✓ Working directory: $SCRIPT_DIR"
    log_info "✓ Build directory: $BUILD_DIR"
    log_info "✓ Data directory: $DATA_DIR"
}

#==============================================================================
# OpenMapTiles Repository
#==============================================================================

setup_openmaptiles_repo() {
    if [ -d "$OPENMAPTILES_DIR/.git" ]; then
        log_info "Updating existing OpenMapTiles repository..."
        if ! cd "$OPENMAPTILES_DIR"; then
            log_error "Failed to enter directory: $OPENMAPTILES_DIR"
            exit 1
        fi
        git fetch origin || {
            log_error "Git fetch failed"
            exit 1
        }
        git checkout "$OPENMAPTILES_BRANCH" || {
            log_error "Git checkout failed"
            exit 1
        }
        git pull origin "$OPENMAPTILES_BRANCH" || {
            log_error "Git pull failed"
            exit 1
        }
    else
        log_info "Cloning OpenMapTiles repository to build/openmaptiles..."
        rm -rf "$OPENMAPTILES_DIR"
        if ! git clone --branch "$OPENMAPTILES_BRANCH" "$OPENMAPTILES_REPO" "$OPENMAPTILES_DIR"; then
            log_error "Git clone failed"
            exit 1
        fi
        if ! cd "$OPENMAPTILES_DIR"; then
            log_error "Failed to enter cloned directory"
            exit 1
        fi
    fi
    log_info "✓ Repository ready at: $OPENMAPTILES_DIR"
}

patch_makefile() {
    log_info "Patching Makefile for correct font download URL..."

    if [ ! -f "Makefile" ]; then
        log_error "Makefile not found in $PWD"
        exit 1
    fi

    if grep -q "v2.0/noto-sans.zip" Makefile; then
        if ! sed -i.bak 's|https://github.com/openmaptiles/fonts/releases/download/v2.0/noto-sans.zip|https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip|' Makefile; then
            log_error "sed failed to patch Makefile"
            exit 1
        fi
        log_info "✓ Makefile patched (backup: Makefile.bak)"
    else
        log_warn "Makefile already patched or pattern not found"
    fi
}

#==============================================================================
# Build Process
#==============================================================================

download_fonts() {
    log_info "Downloading fonts (this may take a while)..."
    if ! make download-fonts; then
        log_error "Font download failed"
        exit 1
    fi
    log_info "✓ Fonts downloaded"
}

build_sprites() {
    log_info "Building sprites..."
    if ! make build-sprite; then
        log_error "Sprite build failed"
        exit 1
    fi
    log_info "✓ Sprites built"
}

build_style() {
    log_info "Building style..."
    if ! make build-style; then
        log_error "Style build failed"
        exit 1
    fi
    log_info "✓ Style built"
}

#==============================================================================
# Copy Assets to Data Directory
#==============================================================================

copy_fonts() {
    log_info "Copying fonts to data/fonts..."

    if [ ! -d "data/fonts" ]; then
        log_error "Fonts directory not found: $OPENMAPTILES_DIR/data/fonts"
        exit 1
    fi

    if ! cp -pr data/fonts "$DATA_DIR/"; then
        log_error "Failed to copy fonts"
        exit 1
    fi

    log_info "✓ Fonts copied to data/fonts"
}

copy_osm_style() {
    log_info "Copying OSM style to data/styles/osm..."

    if [ ! -d "build/style" ]; then
        log_error "Style directory not found: $OPENMAPTILES_DIR/build/style"
        exit 1
    fi

    if ! mkdir -p "$DATA_DIR/styles/osm"; then
        log_error "Failed to create directory: $DATA_DIR/styles/osm"
        exit 1
    fi

    if ! cp -pr build/style/* "$DATA_DIR/styles/osm/"; then
        log_error "Failed to copy OSM style"
        exit 1
    fi

    log_info "✓ OSM style copied to data/styles/osm"
}

#==============================================================================
# Fix style.json with proper permissions
#==============================================================================

fix_style_json() {
    local style_name="$1"
    local style_dir="$DATA_DIR/styles/$style_name"
    local style_file="$style_dir/style.json"

    log_info "Fixing $style_name/style.json..."

    if ! cd "$style_dir"; then
        log_error "Failed to enter directory: $style_dir"
        exit 1
    fi

    if [ ! -f "$style_file" ]; then
        log_error "style.json not found in $style_dir"
        exit 1
    fi

    # Get original permissions
    local original_perms=$(stat -c '%a' "$style_file")

    # Remove old backup if exists
    [ -f "$style_file.backup" ] && rm -f "$style_file.backup"

    # Create new backup
    if ! cp "$style_file" "$style_file.backup"; then
        log_error "Failed to create backup"
        exit 1
    fi

    # Transform JSON
    TMP_FILE=$(mktemp) || {
        log_error "Failed to create temporary file"
        exit 1
    }

    if ! jq 'del(.sources.attribution) | 
        .sources.openmaptiles.url = "mbtiles://{openmaptiles}" | 
        .sprite = "{styleJsonFolder}/sprite"' \
        "$style_file" > "$TMP_FILE"; then
        log_error "jq transformation failed"
        exit 1
    fi

    # Validate JSON
    if ! jq empty "$TMP_FILE" 2>/dev/null; then
        log_error "Generated invalid JSON"
        exit 1
    fi

    # Set proper permissions on temp file BEFORE moving
    chmod "$original_perms" "$TMP_FILE" || {
        log_error "Failed to set permissions on temp file"
        exit 1
    }

    # Replace original
    if ! mv "$TMP_FILE" "$style_file"; then
        log_error "Failed to replace style.json"
        exit 1
    fi

    # Clean up backup after successful transformation
    rm -f "$style_file.backup"

    log_info "✓ $style_name/style.json fixed"
}

#==============================================================================
# OSM Bright Style
#==============================================================================

setup_osm_bright_repo() {
    if [ -d "$OSM_BRIGHT_DIR/.git" ]; then
        log_info "Updating existing OSM Bright repository..."
        if ! cd "$OSM_BRIGHT_DIR"; then
            log_error "Failed to enter directory: $OSM_BRIGHT_DIR"
            exit 1
        fi
        git fetch origin || {
            log_error "Git fetch failed"
            exit 1
        }
        git checkout gh-pages || {
            log_error "Git checkout gh-pages failed"
            exit 1
        }
        git pull origin gh-pages || {
            log_error "Git pull failed"
            exit 1
        }
    else
        log_info "Cloning OSM Bright repository to build/osm-bright-gl-style..."
        rm -rf "$OSM_BRIGHT_DIR"
        if ! git clone --branch gh-pages "$OSM_BRIGHT_REPO" "$OSM_BRIGHT_DIR"; then
            log_error "Git clone failed"
            exit 1
        fi
        if ! cd "$OSM_BRIGHT_DIR"; then
            log_error "Failed to enter cloned directory"
            exit 1
        fi
    fi
    log_info "✓ OSM Bright repository ready at: $OSM_BRIGHT_DIR"
}

copy_osm_bright_style() {
    log_info "Copying OSM Bright style to data/styles/osm-bright..."

    if [ ! -f "style-local.json" ]; then
        log_error "style-local.json not found in $OSM_BRIGHT_DIR"
        exit 1
    fi

    local target_dir="$DATA_DIR/styles/osm-bright"

    if ! mkdir -p "$target_dir"; then
        log_error "Failed to create directory: $target_dir"
        exit 1
    fi

    # Copy style-local.json as style.json
    if ! cp style-local.json "$target_dir/style.json"; then
        log_error "Failed to copy style-local.json"
        exit 1
    fi

    # Copy sprites
    if ! cp sprite* "$target_dir/"; then
        log_error "Failed to copy sprites"
        exit 1
    fi

    # Ensure proper permissions
    chmod 644 "$target_dir"/* || {
        log_warn "Failed to set permissions on OSM Bright files"
    }

    log_info "✓ OSM Bright style copied to data/styles/osm-bright"
}

#==============================================================================
# Main
#==============================================================================

main() {
    # Show warning first
    show_warning

    echo ""
    log_info "=== OpenMapTiles Style Setup ==="
    log_info "Working directory: $SCRIPT_DIR"
    echo ""

    # Phase 1: Validation
    log_info "--- Phase 1: Validation ---"
    check_dependencies
    check_docker
    verify_directories
    echo ""

    # Phase 2: OpenMapTiles OSM Style
    log_info "--- Phase 2: OpenMapTiles OSM Style ---"
    setup_openmaptiles_repo
    patch_makefile
    download_fonts
    build_sprites
    build_style
    copy_fonts
    copy_osm_style
    fix_style_json "osm"
    echo ""

    # Phase 3: OSM Bright Style
    log_info "--- Phase 3: OSM Bright Style ---"
    setup_osm_bright_repo
    copy_osm_bright_style
    fix_style_json "osm-bright"
    echo ""

    # Success
    log_info "=== ✓ Setup Complete ==="
    echo ""
    log_info "Installed styles:"
    log_info "  - OSM:        ./data/styles/osm"
    log_info "  - OSM Bright: ./data/styles/osm-bright"
    log_info "  - Fonts:      ./data/fonts"
    echo ""
    log_info "Build artifacts stored in:"
    log_info "  - ./build/openmaptiles"
    log_info "  - ./build/osm-bright-gl-style"
    echo ""
    log_info "Next steps:"
    log_info "  docker compose restart"
    echo ""
}

main "$@"
