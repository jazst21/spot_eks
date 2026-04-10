import os, signal, sys, time, random, json, threading
from http.server import HTTPServer, BaseHTTPRequestHandler

shutting_down = False

def shutdown(signum, frame):
    global shutting_down
    shutting_down = True
    print("SIGTERM received, draining...", flush=True)
    threading.Timer(5, lambda: sys.exit(0)).start()

signal.signal(signal.SIGTERM, shutdown)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/health":
            code = 503 if shutting_down else 200
            self._send(code, {"status": "draining" if shutting_down else "ok"})
        elif self.path == "/slow":
            time.sleep(random.uniform(1, 2))
            self._info()
        else:
            self._info()
    def _info(self):
        self._send(200, {
            "pod": os.environ.get("HOSTNAME", "?"),
            "node": os.environ.get("NODE_NAME", "?"),
            "az": os.environ.get("AZ", "?"),
            "status": "draining" if shutting_down else "ok",
        })
    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

print("Starting on :8080", flush=True)
HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
