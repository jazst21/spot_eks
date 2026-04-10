#!/usr/bin/env python3
import argparse
import os
from http.server import HTTPServer, SimpleHTTPRequestHandler
from threading import Thread
import socketserver
from pathlib import Path

try:
    import markdown
except ImportError:
    import subprocess, sys
    subprocess.check_call([sys.executable, "-m", "pip", "install", "markdown"])
    import markdown

HTML_TEMPLATE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>
body {{ max-width: 800px; margin: 40px auto; padding: 0 20px; font-family: -apple-system, sans-serif; line-height: 1.6; color: #333; }}
pre {{ background: #f4f4f4; padding: 12px; overflow-x: auto; border-radius: 4px; }}
code {{ background: #f4f4f4; padding: 2px 6px; border-radius: 3px; }}
a {{ color: #0366d6; }}
table {{ border-collapse: collapse; }} th, td {{ border: 1px solid #ddd; padding: 8px; }}
</style></head><body>{body}</body></html>"""

DIR_TEMPLATE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Index of {path}</title>
<style>body {{ max-width: 800px; margin: 40px auto; padding: 0 20px; font-family: -apple-system, sans-serif; }} a {{ color: #0366d6; display: block; padding: 4px 0; }}</style>
</head><body><h1>Index of {path}</h1>{links}</body></html>"""


class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True


class MarkdownHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        # Ignore favicon to prevent blocking
        if self.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return

        path = self.translate_path(self.path)

        if os.path.isdir(path):
            # Check for index.md
            index = os.path.join(path, "index.md")
            if os.path.isfile(index):
                self._serve_md(index)
                return
            # List directory
            self._serve_dir(path)
            return

        if path.endswith(".md") and os.path.isfile(path):
            self._serve_md(path)
            return

        super().do_GET()

    def _serve_md(self, filepath):
        text = Path(filepath).read_text(encoding="utf-8")
        html = markdown.markdown(text, extensions=["fenced_code", "tables"])
        title = Path(filepath).stem
        page = HTML_TEMPLATE.format(title=title, body=html).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(page))
        self.end_headers()
        self.wfile.write(page)

    def _serve_dir(self, dirpath):
        rel = os.path.relpath(dirpath, os.getcwd())
        display = "/" if rel == "." else f"/{rel}/"
        entries = sorted(os.listdir(dirpath))
        links = ""
        if display != "/":
            links += '<a href="../">../</a>'
        for e in entries:
            full = os.path.join(dirpath, e)
            href = f"{e}/" if os.path.isdir(full) else e
            links += f'<a href="{href}">{href}</a>'
        page = DIR_TEMPLATE.format(path=display, links=links).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(page))
        self.end_headers()
        self.wfile.write(page)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Serve and render Markdown files")
    parser.add_argument("--port", type=int, default=8081)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("0.0.0.0", args.port), MarkdownHandler)
    print(f"Serving on http://localhost:{args.port}")
    server.serve_forever()
