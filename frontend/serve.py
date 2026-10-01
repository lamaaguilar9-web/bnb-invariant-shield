# -*- coding: utf-8 -*-
"""
Lightweight Static & API Server for Sentinel Invariant Shield Dashboard.
Serves the institutional Bento Grid Cockpit locally on port 5060.
"""
import os
import sys
import http.server
import socketserver

PORT = 5060
DIRECTORY = os.path.dirname(os.path.abspath(__file__))

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

def start_server():
    os.chdir(DIRECTORY)
    with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
        print(f"[SENTINEL SHIELD] Cockpit UI corriendo en: http://localhost:{PORT}")
        print("[SENTINEL SHIELD] Presiona Ctrl+C para detener.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n[SENTINEL SHIELD] Servidor detenido de forma segura.")

if __name__ == "__main__":
    start_server()
