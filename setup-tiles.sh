#!/bin/bash
set -euo pipefail

#==============================================================================
# Planetiler Setup & MBTiles Generation Script
#
# This script automates the setup and execution of Planetiler:
# - Installs Java 21 JRE if needed
# - Installs required dependencies (curl, jq) if needed
# - Downloads latest Planetiler release
# - Detects optimal hardware settings (RAM, CPU cores)
# - Generates MBTiles for specified region
# - Moves output to ./data/tiles/
#
# Usage: ./setup-planetiler.sh [region] [threads]
#   region:  OSM region name (default: germany)
#   threads: Number of threads (default: auto-detect)
#==============================================================================

# Get script directory and set paths relative to it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build/planetiler"
DATA_DIR="$SCRIPT_DIR/data"
TILES_DIR="$DATA_DIR/tiles"

# Configuration
REGION="${1:-germany}"
THREADS="${2:-auto}"
PLANETILER_REPO="onthegomap/planetiler"
PLANETILER_JAR="$BUILD_DIR/planetiler.jar"

# Logging helpers
log_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# Cleanup on exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Script failed with exit code $exit_code"
    fi
}
trap cleanup EXIT

#==============================================================================
# System Detection
#==============================================================================

detect_system_resources() {
    log_info "Detecting system resources..."

    # Detect available RAM (in GB)
    local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_gb=$((total_ram_kb / 1024 / 1024))

    # Detect CPU cores
    local cpu_cores=$(nproc)

    # Calculate optimal settings
    # Use 80% of RAM, minimum 2GB, maximum 32GB
    local ram_for_java=$((total_ram_gb * 80 / 100))
    if [ $ram_for_java -lt 2 ]; then
        ram_for_java=2
    elif [ $ram_for_java -gt 32 ]; then
        ram_for_java=32
    fi

    # Use 80% of CPU cores, minimum 1, maximum 16
    local threads_auto=$((cpu_cores * 80 / 100))
    if [ $threads_auto -lt 1 ]; then
        threads_auto=1
    elif [ $threads_auto -gt 16 ]; then
        threads_auto=16
    fi

    # Set threads if auto-detect requested
    if [ "$THREADS" = "auto" ]; then
        THREADS=$threads_auto
    fi

    # Set Java options only if not already set
    if [ -z "${JAVA_TOOL_OPTIONS:-}" ]; then
        export JAVA_TOOL_OPTIONS="-Xms${ram_for_java}G -Xmx${ram_for_java}G"
        java_heap_msg="${ram_for_java}GB (Xms/Xmx, auto-detected)"
    else
        java_heap_msg="Custom (JAVA_TOOL_OPTIONS already set)"
    fi

    log_info "✓ System resources detected:"
    log_info "  Total RAM: ${total_ram_gb}GB"
    log_info "  CPU Cores: ${cpu_cores}"
    log_info "  Java Heap: ${java_heap_msg}"
    log_info "  Threads:   ${THREADS}"
}

#==============================================================================
# Dependency Checks
#==============================================================================

check_dependencies() {
    log_info "Checking dependencies..."

    local missing=()

    # Check all dependencies
    for cmd in curl jq java; do
        if ! command -v "$cmd" &> /dev/null; then
            if [ "$cmd" = "java" ]; then
                missing+=("openjdk-21-jre")
            else
                missing+=("$cmd")
            fi
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

check_java() {
    log_info "Validating Java version..."

    if ! command -v java &> /dev/null; then
        log_error "Java not found after installation"
        exit 1
    fi

    local java_version=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}')
    local java_major=$(echo "$java_version" | cut -d'.' -f1)

    if [ "$java_major" -lt 21 ]; then
        log_error "Java $java_version found, but Java 21+ required"
        log_error "Please install OpenJDK 21 manually: apt-get install openjdk-21-jre"
        exit 1
    fi

    log_info "✓ Java $java_version validated"
}

verify_directories() {
    log_info "Verifying directory structure..."

    if [ ! -f "$SCRIPT_DIR/docker-compose.yaml" ]; then
        log_warn "docker-compose.yaml not found in $SCRIPT_DIR"
        log_warn "Are you running this from the tileserver directory?"
    fi

    # Create directories
    mkdir -p "$BUILD_DIR"
    mkdir -p "$TILES_DIR"

    log_info "✓ Working directory: $SCRIPT_DIR"
    log_info "✓ Build directory: $BUILD_DIR"
    log_info "✓ Tiles directory: $TILES_DIR"
}

#==============================================================================
# Planetiler Download
#==============================================================================

download_planetiler() {
    log_info "Checking for latest Planetiler release..."

    # Get latest release info from GitHub API
    local api_url="https://api.github.com/repos/$PLANETILER_REPO/releases/latest"
    local release_info

    if ! release_info=$(curl -s "$api_url"); then
        log_error "Failed to fetch release information from GitHub"
        exit 1
    fi

    local latest_version=$(echo "$release_info" | jq -r '.tag_name')
    local download_url=$(echo "$release_info" | jq -r '.assets[] | select(.name | endswith(".jar")) | .browser_download_url')

    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        log_error "Could not find JAR download URL in latest release"
        exit 1
    fi

    log_info "Latest version: $latest_version"

    # Check if already downloaded
    if [ -f "$PLANETILER_JAR" ]; then
        log_info "Planetiler JAR already exists at: $PLANETILER_JAR"
        log_info "Download latest version? (y/N) [10s timeout, default: N]"

        if read -t 10 -n 1 -r; then
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "Downloading new version..."
            else
                log_info "Using existing JAR"
                return 0
            fi
        else
            echo
            log_info "Timeout - using existing JAR"
            return 0
        fi
    fi

    # Download
    log_info "Downloading Planetiler $latest_version..."
    log_info "URL: $download_url"

    if ! curl -L --progress-bar -o "$PLANETILER_JAR" "$download_url"; then
        log_error "Download failed"
        exit 1
    fi

    # Verify download
    if [ ! -f "$PLANETILER_JAR" ] || [ ! -s "$PLANETILER_JAR" ]; then
        log_error "Downloaded file is missing or empty"
        exit 1
    fi

    log_info "✓ Planetiler downloaded: $PLANETILER_JAR"
}

#==============================================================================
# MBTiles Generation
#==============================================================================

generate_mbtiles() {
    log_info "Generating MBTiles for region: $REGION"

    local output_file="$BUILD_DIR/${REGION}.mbtiles"

    # Remove old output if exists
    if [ -f "$output_file" ]; then
        log_warn "Removing existing output: $output_file"
        rm -f "$output_file"
    fi

    # Change to build directory
    if ! cd "$BUILD_DIR"; then
        log_error "Failed to enter build directory"
        exit 1
    fi

    log_info "Running Planetiler..."
    log_info "Command: java -jar planetiler.jar --download --area=$REGION --profile=openmaptiles --output=${REGION}.mbtiles --threads=$THREADS"
    echo ""

    # Run Planetiler
    if ! java -jar planetiler.jar \
        --download \
        --area="$REGION" \
        --profile=openmaptiles \
        --output="${REGION}.mbtiles" \
        --threads="$THREADS"; then
        log_error "Planetiler execution failed"
        exit 1
    fi

    echo ""
    log_info "✓ MBTiles generation complete"

    # Verify output
    if [ ! -f "$output_file" ]; then
        log_error "Output file not created: $output_file"
        exit 1
    fi

    local file_size=$(du -h "$output_file" | cut -f1)
    log_info "✓ Output file size: $file_size"
}

#==============================================================================
# Deploy MBTiles
#==============================================================================

deploy_mbtiles() {
    log_info "Deploying MBTiles to data/tiles..."

    local source_file="$BUILD_DIR/${REGION}.mbtiles"
    local target_file="$TILES_DIR/tiles.mbtiles"

    if [ ! -f "$source_file" ]; then
        log_error "Source file not found: $source_file"
        exit 1
    fi

    # Remove existing file if present (no backup for large files)
    if [ -f "$target_file" ]; then
        local file_size=$(du -h "$target_file" | cut -f1)
        log_warn "Removing existing tiles.mbtiles ($file_size)"
        if ! rm -f "$target_file"; then
            log_error "Failed to remove existing file"
            exit 1
        fi
    fi

    # Move file to generic name
    if ! mv "$source_file" "$target_file"; then
        log_error "Failed to move MBTiles to data/tiles"
        exit 1
    fi

    # Set permissions
    chmod 644 "$target_file" || {
        log_warn "Failed to set permissions on $target_file"
    }

    log_info "✓ MBTiles deployed: $target_file"
    log_info "  Source region: $REGION"
}

#==============================================================================
# Main
#==============================================================================

show_usage() {
    cat << EOF
Usage: $0 [region] [threads]

Arguments:
  region   OSM region name (default: germany)
           Examples: germany, europe, north-america, planet
  threads  Number of threads (default: auto-detect)

Examples:
  $0                        # Generate germany.mbtiles with auto-detected settings
  $0 europe                 # Generate europe.mbtiles
  $0 germany 8              # Generate germany.mbtiles with 8 threads

Environment variables:
  JAVA_TOOL_OPTIONS        Set custom Java heap size (auto-detected by default)

EOF
}

main() {
    # Handle help flag
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        show_usage
        exit 0
    fi

    echo ""
    log_info "=== Planetiler MBTiles Generator ==="
    log_info "Region: $REGION"
    echo ""

    # Phase 1: System Check
    log_info "--- Phase 1: System Check ---"
    check_dependencies
    check_java
    detect_system_resources
    verify_directories
    echo ""

    # Phase 2: Download Planetiler
    log_info "--- Phase 2: Download Planetiler ---"
    download_planetiler
    echo ""

    # Phase 3: Generate MBTiles
    log_info "--- Phase 3: Generate MBTiles ---"
    log_warn "This may take a long time depending on region size!"
    generate_mbtiles
    echo ""

    # Phase 4: Deploy
    log_info "--- Phase 4: Deploy MBTiles ---"
    deploy_mbtiles
    echo ""

    # Success
    log_info "=== ✓ MBTiles Generation Complete ==="
    echo ""
    log_info "Output file: ./data/tiles/tiles.mbtiles"
    log_info "Source region: $REGION"
    log_info "Build artifacts in: ./build/planetiler/"
    echo ""
    log_info "Your config.json should reference:"
    log_info '  "data": {'
    log_info '    "openmaptiles": {'
    log_info '      "mbtiles": "tiles/tiles.mbtiles"'
    log_info '    }'
    log_info '  }'
    echo ""
    log_info "Then restart tileserver:"
    log_info "  docker compose restart"
    echo ""
}

main "$@"
