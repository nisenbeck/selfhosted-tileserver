# Minimal TileServer GL stand-in for tests/run.sh.
# Serves a fixed tile with a content-based weak ETag and counts tile requests.
# Style "missing" returns 404 (like TileServer GL while it loads), style "error" 503.
import hashlib
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TILE = b"\x89PNG\r\n\x1a\n" + b"mock-tile" * 64
ETAG = 'W/"%x-%s"' % (
    len(TILE),
    base64.b64encode(hashlib.sha1(TILE).digest()).decode().rstrip("="),
)
count = 0


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        global count
        if self.path == "/__count":
            body = str(count).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
        elif self.path.startswith(("/styles/missing/", "/styles/error/")):
            count += 1
            body = b"error"
            self.send_response(404 if self.path.startswith("/styles/missing/") else 503)
        elif self.path.startswith("/styles/"):
            count += 1
            body = TILE
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("ETag", ETAG)
            # Like TileServer GL: Last-Modified is the render time.
            self.send_header("Last-Modified", self.date_time_string())
            # nginx must ignore, hide or replace these.
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
        else:
            body = b"not found"
            self.send_response(404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
