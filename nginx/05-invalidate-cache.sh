#!/bin/sh
# Clears the nginx tile cache when the data in /data has changed.
# Runs from /docker-entrypoint.d/ before nginx starts.
# Always exits 0: a failing entrypoint script stops the container.
# No "set -e": every error is handled explicitly.

ME=$(basename "$0")
DATA_DIR=/data
CACHE_DIR=/var/cache/nginx
STAMP="$CACHE_DIR/data.fingerprint"
LIST=/tmp/data.list
SORTED=/tmp/data.list.sorted
UNREADABLE=/tmp/data.unreadable

log()   { echo "$ME: $*"; }
warn()  { echo "$ME: WARNING: $*" >&2; }
error() { echo "$ME: ERROR: $*" >&2; }

main() {
    # Test hook: simulate an unexpected failure.
    if [ -n "${INVALIDATE_CACHE_FORCE_ERROR:-}" ]; then
        error "forced error (INVALIDATE_CACHE_FORCE_ERROR is set)"
        return 1
    fi

    # 1. A missing MBTiles file usually means an incorrect mount. Do not touch the cache.
    found=
    for f in "$DATA_DIR"/tiles/*.mbtiles; do
        if [ -f "$f" ] && [ -r "$f" ]; then
            found=1
            break
        fi
    done
    if [ -z "$found" ]; then
        warn "no readable *.mbtiles file in $DATA_DIR/tiles, cache not changed"
        return 0
    fi

    # 2. Fingerprint from path, size and mtime of all data files (no content hash).
    #    Write to files and check exit codes: dash has no reliable pipefail.
    if ! find "$DATA_DIR" -path "$DATA_DIR/cache" -prune -o ! -readable -print > "$UNREADABLE"; then
        error "cannot scan $DATA_DIR, cache not changed"
        return 1
    fi
    if [ -s "$UNREADABLE" ]; then
        error "unreadable entries in $DATA_DIR, cache not changed:"
        head -n 10 "$UNREADABLE" >&2
        return 1
    fi
    if ! find "$DATA_DIR" -path "$DATA_DIR/cache" -prune -o -type f -printf '%P %s %T@\n' > "$LIST"; then
        error "cannot list $DATA_DIR, cache not changed"
        return 1
    fi
    if ! LC_ALL=C sort -o "$SORTED" "$LIST"; then
        error "cannot sort file list, cache not changed"
        return 1
    fi
    if ! sum=$(sha256sum < "$SORTED"); then
        error "cannot calculate fingerprint, cache not changed"
        return 1
    fi
    new=${sum%% *}
    if [ -z "$new" ]; then
        error "empty fingerprint, cache not changed"
        return 1
    fi

    # 3. Same data as at the last start: keep the cache.
    old=$(cat "$STAMP" 2>/dev/null)
    if [ "$old" = "$new" ]; then
        log "data not changed, cache kept"
        return 0
    fi

    # 4. Data changed or state unknown: clear everything except the stamp.
    if [ -z "$(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name data.fingerprint -print -quit)" ]; then
        log "cache is empty"
    elif [ -z "$old" ]; then
        log "no stamp file, clearing cache"
    else
        log "data changed, clearing cache"
    fi
    if ! find "$CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name data.fingerprint -exec rm -rf -- {} +; then
        error "cannot clear $CACHE_DIR, stamp not written"
        return 1
    fi
    if ! { printf '%s\n' "$new" > "$STAMP.tmp" && mv -f "$STAMP.tmp" "$STAMP"; }; then
        error "cannot write $STAMP"
        rm -f "$STAMP.tmp"
        return 1
    fi
    log "stamp written, fingerprint $new"
    return 0
}

( main )
rc=$?
rm -f "$LIST" "$SORTED" "$UNREADABLE"
if [ "$rc" -ne 0 ]; then
    error "cache invalidation failed (exit $rc), nginx starts with the existing cache"
fi
exit 0
