#!/bin/sh
# Clears the nginx tile cache when the data in /data has changed.
# Runs from /docker-entrypoint.d/ before nginx starts. The old cache is moved
# to trash-* (fast rename) and deleted in the background while nginx runs.
# Always exits 0: a failing entrypoint script stops the container.
# No "set -e": every error is handled explicitly.

ME=$(basename "$0")
DATA_DIR=/data
CACHE_DIR=/var/cache/nginx
STAMP="$CACHE_DIR/data.fingerprint"
LIST=/tmp/data.list
SORTED=/tmp/data.list.sorted

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
    #    [ -f ] follows symbolic links, a dangling link does not count.
    found=
    for f in "$DATA_DIR"/tiles/*.mbtiles; do
        if [ -f "$f" ]; then
            found=1
            break
        fi
    done
    if [ -z "$found" ]; then
        warn "no *.mbtiles file in $DATA_DIR/tiles, cache not changed"
        return 0
    fi

    # 2. Fingerprint from path, size and mtime of all data files (no content hash).
    #    Metadata needs no read permission on the files. -L uses the link targets.
    #    find fails on unreadable directories and link loops: then use no partial list.
    #    Write to files and check exit codes: dash has no reliable pipefail.
    if ! find -L "$DATA_DIR" -path "$DATA_DIR/cache" -prune -o ! -type d -printf '%P %s %T@\n' > "$LIST"; then
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

    # 4. Data changed or state unknown: move everything except the stamp and
    #    older trash into a new trash directory. nginx creates tiles/ again.
    if [ -z "$(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name data.fingerprint ! -name 'trash-*' -print -quit)" ]; then
        log "cache is empty"
    else
        if [ -z "$old" ]; then
            log "no stamp file, clearing cache"
        else
            log "data changed, clearing cache"
        fi
        trash="$CACHE_DIR/trash-$(date +%s)-$$"
        if ! mkdir "$trash"; then
            error "cannot create $trash, stamp not written"
            return 1
        fi
        if ! find "$CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name data.fingerprint ! -name 'trash-*' -exec mv -t "$trash" -- {} +; then
            error "cannot move the cache to $trash, stamp not written"
            return 1
        fi
    fi
    if ! { printf '%s\n' "$new" > "$STAMP.tmp" && mv -f "$STAMP.tmp" "$STAMP"; }; then
        error "cannot write $STAMP"
        rm -f "$STAMP.tmp"
        return 1
    fi
    log "stamp written, fingerprint $new"
    return 0
}

# Delete all trash directories in the background, also those of an earlier
# start that stopped before the deletion was complete. When rm ends, nginx
# (PID 1) logs "unknown process ... exited with code 0". This is expected.
purge_trash() {
    set -- "$CACHE_DIR"/trash-*
    [ -e "$1" ] || return 0
    log "deleting old cache in the background: $*"
    ( nice -n 19 rm -rf -- "$@" || error "cannot delete $*" ) < /dev/null &
}

( main )
rc=$?
rm -f "$LIST" "$SORTED"
if [ "$rc" -ne 0 ]; then
    error "cache invalidation failed (exit $rc), nginx starts with the existing cache"
fi
purge_trash
exit 0
