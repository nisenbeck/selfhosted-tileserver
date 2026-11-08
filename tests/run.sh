#!/bin/sh
# Tests for nginx/default.conf.template and nginx/05-invalidate-cache.sh.
# Needs only docker and a POSIX shell. Run: ./tests/run.sh
# A mock upstream replaces TileServer GL. Takes about 2 minutes, because the
# last test waits for the nginx cache loader (starts 60 s after nginx).

set -u
umask 022

REPO=$(cd "$(dirname "$0")/.." && pwd)
NGINX_IMAGE=docker.io/nginxinc/nginx-unprivileged:1.31
MOCK_IMAGE=docker.io/library/python:3.14-slim
SCRIPT=05-invalidate-cache.sh

ID=tsc-test-$$
NET=$ID
MOCK=$ID-mock
NGINX=$ID-nginx
WORK=$(mktemp -d)
DATA=$WORK/data
CACHE=$DATA/cache           # same layout as production: cache inside the data dir
C=/var/cache/nginx          # cache path in the container
TILE=/styles/test/1/0/0.png
DAY=86400

PASSED=0
FAILED=0

# --- helpers ---------------------------------------------------------------

pass() { PASSED=$((PASSED + 1)); echo "  ok   $*"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL $*"; }
check() { # check "description" command...
    desc=$1; shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}
section() { echo; echo "== $*"; }

cleanup() {
    docker rm -f "$NGINX" "$MOCK" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    # Cache files belong to uid 101. Delete them in a container.
    docker run --rm -u 0 --entrypoint rm -v "$WORK:/w" "$NGINX_IMAGE" -rf /w/data/cache >/dev/null 2>&1
    chmod -R u+rwX "$WORK" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Run a shell command as uid 101 with the cache mounted (nginx may be stopped).
in_cache() {
    docker run --rm --entrypoint sh -v "$CACHE:$C" "$NGINX_IMAGE" -c "$1"
}

reset_cache() {
    docker run --rm -u 0 --entrypoint sh -v "$DATA:/d" "$NGINX_IMAGE" \
        -c 'rm -rf /d/cache && mkdir /d/cache && chown 101:101 /d/cache'
}

# Start a fresh nginx container on the existing cache. Extra args go to docker run.
start_nginx() {
    docker rm -f "$NGINX" >/dev/null 2>&1
    docker run -d --name "$NGINX" --network "$NET" \
        -e TILESERVER_APP="$MOCK:8080" \
        -e CACHE_MAX_SIZE=1234m -e CACHE_MIN_FREE=56m -e CACHE_INACTIVE=7d \
        "$@" \
        -v "$REPO/nginx:/etc/nginx/templates:ro" \
        -v "$REPO/nginx/$SCRIPT:/docker-entrypoint.d/$SCRIPT:ro" \
        -v "$DATA:/data:ro" \
        -v "$CACHE:$C" \
        "$NGINX_IMAGE" >/dev/null || return 1
    i=0
    while [ $i -lt 30 ]; do
        code=$(docker exec "$NGINX" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/ 2>/dev/null)
        [ "$code" = 404 ] && return 0
        if [ "$(docker inspect -f '{{.State.Running}}' "$NGINX" 2>/dev/null)" != true ]; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "  nginx did not start:"
    docker logs "$NGINX" 2>&1 | sed 's/^/    /'
    return 1
}

logs() { docker logs "$NGINX" 2>&1; }
log_has() { logs | grep -q -- "$1"; }

# Response headers of a tile request. Extra args go to curl.
req() {
    req_path "$TILE" "$@"
}
req_path() {
    path=$1; shift
    docker exec "$NGINX" curl -s -D - -o /dev/null "$@" "http://127.0.0.1:8081$path" | tr -d '\r'
}
header() { printf '%s\n' "$2" | grep -i "^$1:" | head -n 1 | sed 's/^[^:]*: *//'; }
header_count() { printf '%s\n' "$2" | grep -ci "^$1:"; }
status() { printf '%s\n' "$1" | head -n 1 | cut -d ' ' -f 2; }
count() { docker exec "$NGINX" curl -s "http://$MOCK:8080/__count"; }
stamp() { docker exec "$NGINX" cat "$C/data.fingerprint" 2>/dev/null; }
tile_files() { docker exec "$NGINX" find "$C/tiles" -type f | wc -l; }

eq() { [ "$1" = "$2" ]; }
ne() { [ "$1" != "$2" ]; }
is_hash() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }

# --- setup -----------------------------------------------------------------

echo "Work directory: $WORK"
mkdir -p "$DATA/tiles" "$DATA/styles/test" "$DATA/fonts/Test Regular"
echo dummy > "$DATA/tiles/test.mbtiles"
echo '{}' > "$DATA/config.json"
echo '{}' > "$DATA/styles/test/style.json"
echo x > "$DATA/fonts/Test Regular/0-255.pbf"
mkdir -p "$CACHE"
reset_cache || exit 1

docker network create "$NET" >/dev/null || exit 1
docker run -d --name "$MOCK" --network "$NET" \
    -v "$REPO/tests/mock_tileserver.py:/mock.py:ro" \
    "$MOCK_IMAGE" python -u /mock.py >/dev/null || exit 1

# --- tests -----------------------------------------------------------------

section "Compose defaults for the cache limits"
cfg=$(cd "$REPO" && CACHE_MAX_SIZE='' CACHE_MIN_FREE='' CACHE_INACTIVE='' docker compose config 2>/dev/null)
check "CACHE_MAX_SIZE defaults to 25g" eq "$(printf '%s\n' "$cfg" | grep -c 'CACHE_MAX_SIZE: 25g')" 1
check "CACHE_MIN_FREE defaults to 20g" eq "$(printf '%s\n' "$cfg" | grep -c 'CACHE_MIN_FREE: 20g')" 1
check "CACHE_INACTIVE defaults to 30d" eq "$(printf '%s\n' "$cfg" | grep -c 'CACHE_INACTIVE: 30d')" 1

section "First start, no stamp, cache has old files"
in_cache "mkdir -p $C/0/ab $C/f/12 && echo x > $C/0/ab/0123456789abcdef && echo x > $C/.hidden" || fail "prepare cache"
start_nginx || exit 1
check "old entries removed" eq "$(docker exec "$NGINX" ls -A "$C" | tr '\n' ' ')" "data.fingerprint tiles "
check "stamp written" is_hash "$(stamp)"
check "log: clearing cache" log_has "no stamp file, clearing cache"

section "First start, no stamp, cache is empty"
docker rm -f "$NGINX" >/dev/null
reset_cache
start_nginx || exit 1
check "stamp written" is_hash "$(stamp)"
check "log: cache is empty" log_has "cache is empty"

section "Rendered configuration"
conf=$(docker exec "$NGINX" cat /etc/nginx/conf.d/default.conf)
check "cache path /var/cache/nginx/tiles" eq "$(printf '%s\n' "$conf" | grep -c 'proxy_cache_path /var/cache/nginx/tiles ')" 1
check "max_size and min_free from env" eq "$(printf '%s\n' "$conf" | grep -c 'max_size=1234m min_free=56m')" 1
check "inactive from env" eq "$(printf '%s\n' "$conf" | grep -c 'inactive=7d ')" 1

section "Caching and response headers"
n0=$(count)
h=$(req)
check "first request is MISS" eq "$(header X-Cache-Status "$h")" MISS
check "upstream called once" eq "$(count)" $((n0 + 1))
h=$(req)
check "second request is HIT" eq "$(header X-Cache-Status "$h")" HIT
check "upstream not called again" eq "$(count)" $((n0 + 1))
check "Cache-Control value" eq "$(header Cache-Control "$h")" "max-age=86400, stale-while-revalidate=604800"
check "one Cache-Control header" eq "$(header_count Cache-Control "$h")" 1
check "one X-Cache-Status header" eq "$(header_count X-Cache-Status "$h")" 1
check "one Access-Control-Allow-Origin header" eq "$(header_count Access-Control-Allow-Origin "$h")" 1
check "no Last-Modified header" eq "$(header_count Last-Modified "$h")" 0
etag=$(header ETag "$h")
check "ETag passed through" ne "$etag" ""

section "Error responses are not cached"
for code_style in 404:missing 503:error; do
    code=${code_style%%:*}
    path=/styles/${code_style#*:}/1/0/0.png
    n0=$(count)
    h1=$(req_path "$path")
    h2=$(req_path "$path")
    check "$code passed through" eq "$(status "$h1")" "$code"
    check "$code not cached (second request is $(header X-Cache-Status "$h2"))" eq "$(header X-Cache-Status "$h2")" MISS
    check "$code: upstream called twice" eq "$(count)" $((n0 + 2))
done

section "Conditional request with the ETag"
n0=$(count)
h=$(req -H "If-None-Match: $etag")
check "304 from nginx" eq "$(status "$h")" 304
check "upstream not called" eq "$(count)" "$n0"
check "Cache-Control on 304" eq "$(header Cache-Control "$h")" "max-age=86400, stale-while-revalidate=604800"
section "Cache duration"
# Cache file header (64-bit): 8-byte version, then 8-byte little-endian valid_sec.
f=$(docker exec "$NGINX" find "$C/tiles" -type f | head -n 1)
valid=$(docker exec "$NGINX" od -An -t u8 -j 8 -N 8 "$f" | tr -d ' ')
now=$(date +%s)
delta=$((valid - now))
check "valid time is 365 days (got $((delta / DAY)) d)" \
    test "$delta" -gt $((365 * DAY - 600)) -a "$delta" -le $((365 * DAY + 600))

section "Restart, data not changed"
s0=$(stamp)
start_nginx || exit 1
n0=$(count)
check "log: data not changed" log_has "data not changed, cache kept"
check "stamp unchanged" eq "$(stamp)" "$s0"
check "tile is HIT" eq "$(header X-Cache-Status "$(req)")" HIT
check "upstream not called" eq "$(count)" "$n0"

section "No MBTiles file"
mv "$DATA/tiles/test.mbtiles" "$WORK/test.mbtiles"
echo changed >> "$DATA/config.json"
start_nginx || exit 1
check "log: warning" log_has "WARNING: no readable \*.mbtiles"
check "stamp unchanged" eq "$(stamp)" "$s0"
check "cache kept" eq "$(header X-Cache-Status "$(req)")" HIT
mv "$WORK/test.mbtiles" "$DATA/tiles/test.mbtiles"

section "Unreadable file in the data directory"
chmod 000 "$DATA/styles/test/style.json"
start_nginx || exit 1
check "nginx starts" true
check "log: error" log_has "ERROR: unreadable entries"
check "stamp unchanged" eq "$(stamp)" "$s0"
check "cache kept" eq "$(header X-Cache-Status "$(req)")" HIT
chmod 644 "$DATA/styles/test/style.json"

section "Unreadable directory in the data directory"
chmod 000 "$DATA/fonts/Test Regular"
start_nginx || exit 1
check "log: error" log_has "ERROR:"
check "stamp unchanged" eq "$(stamp)" "$s0"
check "cache kept" eq "$(header X-Cache-Status "$(req)")" HIT
chmod 755 "$DATA/fonts/Test Regular"

section "Unexpected error in the script"
start_nginx -e INVALIDATE_CACHE_FORCE_ERROR=1 || exit 1
check "nginx starts" true
check "log: error" log_has "ERROR: cache invalidation failed"
check "stamp unchanged" eq "$(stamp)" "$s0"
check "cache kept" eq "$(header X-Cache-Status "$(req)")" HIT

section "Restart after a data change"
# config.json was changed in the "No MBTiles file" section.
start_nginx || exit 1
check "log: data changed" log_has "data changed, clearing cache"
s1=$(stamp)
check "stamp has a new value" test -n "$s1" -a "$s1" != "$s0"
check "cache is empty" eq "$(tile_files)" 0
n0=$(count)
check "tile is MISS" eq "$(header X-Cache-Status "$(req)")" MISS
check "upstream called" eq "$(count)" $((n0 + 1))

section "Stamp file after the cache loader ran"
# The loader deletes unknown files in the cache path. A probe file shows that it ran.
docker exec "$NGINX" sh -c "echo x > $C/tiles/.probe" || fail "create probe"
echo "  waiting for the cache loader (up to 120 s) ..."
i=0
while [ $i -lt 120 ] && docker exec "$NGINX" test -e "$C/tiles/.probe"; do
    sleep 2
    i=$((i + 2))
done
check "cache loader ran (probe deleted after ${i} s)" docker exec "$NGINX" test ! -e "$C/tiles/.probe"
check "stamp still exists" eq "$(stamp)" "$s1"
check "cached tile still HIT" eq "$(header X-Cache-Status "$(req)")" HIT

# --- result ----------------------------------------------------------------

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
