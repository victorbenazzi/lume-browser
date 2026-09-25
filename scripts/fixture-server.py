"""Serve integration fixtures on an available loopback port."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from email.parser import BytesParser
from email.policy import default
import html
import os
import socket
import sys
import time
from urllib.parse import urlsplit

fixtures = Path(__file__).resolve().parent.parent / "tests/fixtures"
class FixtureHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(fixtures), **kwargs)

    def page(self, content, cookie=None):
        body = content.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        route = urlsplit(self.path).path
        if route == "/session/set":
            self.page("<title>Session Seed</title><script>localStorage.setItem('lume-fixture','persisted');document.title='Session Seed Ready';</script>",
                      "lume_fixture_session=synthetic-session; HttpOnly; SameSite=Lax; Path=/")
        elif route == "/session/check":
            cookie_ok = "lume_fixture_session=synthetic-session" in self.headers.get("Cookie", "")
            self.page("<title>Session Check</title><script>document.title=" +
                      ("localStorage.getItem('lume-fixture')==='persisted'?'Session PASS':'Storage FAIL'" if cookie_ok else "'Cookie FAIL'") + ";</script>")
        elif route == "/network/fail":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
        elif route == "/oauth/start":
            port = self.server.server_port
            self.page(f'<title>Login de teste</title><h1>Conta fictícia</h1><p>Este fluxo não acessa nenhuma conta real.</p><a href="http://127.0.0.1:{port}/oauth/callback">Continuar autenticação</a>')
        elif route == "/oauth/callback":
            self.page("<title>OAuth callback</title><script>if(window.opener){window.opener.postMessage('lume-auth-pass',location.origin);window.close();}else{document.title='OAuth opener FAIL';}</script>")
        elif route in ("/download.txt", "/download-slow.bin"):
            slow = route.endswith(".bin")
            body = b"Lume download fixture\n" if not slow else b"x" * 65536
            repetitions = 256 if slow else 1
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="' + ("lume-slow.bin" if slow else "lume-download.txt") + '"')
            self.send_header("Content-Length", str(len(body) * repetitions))
            self.end_headers()
            try:
                for _ in range(repetitions):
                    self.wfile.write(body)
                    self.wfile.flush()
                    if slow:
                        time.sleep(0.1)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            super().do_GET()

    def do_POST(self):
        if urlsplit(self.path).path != "/upload":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length > 2 * 1024 * 1024:
            self.send_error(413)
            return
        body = self.rfile.read(length)
        message = BytesParser(policy=default).parsebytes(
            ("Content-Type: " + self.headers.get("Content-Type", "") + "\r\n\r\n").encode() + body)
        files = [(part.get_filename(), part.get_payload(decode=True)) for part in message.walk() if part.get_filename()]
        if files:
            name, data = files[0]
            self.page(f"<title>Upload PASS</title><h1>Upload recebido</h1><p>{html.escape(name)}: {len(data)} bytes</p>")
        else:
            self.page("<title>Upload FAIL</title><h1>Nenhum arquivo recebido</h1>")

server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 0), FixtureHandler)
Path(sys.argv[1]).write_text(str(server.server_address[1]))
Path(sys.argv[1] + ".pid").write_text(str(os.getpid()))
server.serve_forever()
