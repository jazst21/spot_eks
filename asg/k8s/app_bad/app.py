import os, time, random, json
from http.server import HTTPServer, BaseHTTPRequestHandler

# NO SIGTERM handler — app crashes immediately on kill
# NO graceful drain — in-flight requests dropped

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/slow":
            time.sleep(random.uniform(1, 2))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({
            "pod": os.environ.get("HOSTNAME", "?"),
            "status": "ok",
        }).encode())

print("Starting on :8080 (NO graceful shutdown)", flush=True)
HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
