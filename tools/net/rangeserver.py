# Tiny HTTP server with Range support, for testing network playback.
# usage: python3 -I rangeserver.py <dir> <port> [bytes_per_second]   (0 = unlimited)
import http.server, os, sys, time
root, port, bps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 0
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        path = os.path.join(root, os.path.basename(self.path.split("?")[0]))
        if not os.path.isfile(path): self.send_error(404); return
        size = os.path.getsize(path); start, end = 0, size - 1
        r = self.headers.get("Range")
        if r and r.startswith("bytes="):
            a, _, b = r[6:].partition("-")
            start = int(a) if a else 0
            end = int(b) if b else size - 1
        self.send_response(206 if r else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if r: self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start); left = end - start + 1
                while left > 0:
                    chunk = f.read(min(16384, left))
                    if not chunk: break
                    self.wfile.write(chunk); left -= len(chunk)
                    if bps: time.sleep(len(chunk) / bps)
        except (BrokenPipeError, ConnectionResetError): pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
