"""A tiny in-memory stand-in for the relay, on 127.0.0.1 only, that records every request.

Implements the paths the plugin uses, with the box rules of research/launch-with-claude-spec.md:
/v1/pair/start, /v1/pair/join, GET /v1/pair/<code>, PUT|GET /v1/state, POST /v1/push/notify, DELETE /v1/box.
Like the real relay, a deleted box stays gone: every later request with it gets 410 {"error": "gone"}.
"""
import hashlib, json, re, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HEX64 = re.compile(r"^[0-9a-f]{64}$")


class Relay:
    def __init__(self):
        self.requests = []          # every request: method, path, headers, body text
        self.pairs = {}             # code -> {"phone": pub, "computer": pub, "name": str}
        self.boxes = {}             # box -> {"auth": hash, "state": text, "v": n}
        self.gone = set()           # hashes of deleted boxes
        self.lock = threading.Lock()
        relay = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _reply(self, code, obj):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _handle(self):
                n = int(self.headers.get("content-length") or 0)
                body = self.rfile.read(n).decode() if n else ""
                rec = {"method": self.command, "path": self.path, "body": body, "at": time.time(),
                       "headers": {k.lower(): v for k, v in self.headers.items()}}
                with relay.lock:
                    relay.requests.append(rec)
                    code, obj = relay.route(self.command, self.path, rec["headers"], body)
                self._reply(code, obj)

            do_GET = do_POST = do_PUT = do_DELETE = _handle

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()

    def route(self, method, path, headers, body):
        if path.startswith("/v1/pair/"):
            return self.pair(method, path, body)
        box, auth = headers.get("x-box", ""), headers.get("x-auth", "")
        if not HEX64.match(box) or not HEX64.match(auth):
            return 401, {"error": "box"}
        gone_id = hashlib.sha256(("gone|" + box).encode()).hexdigest()
        if method == "DELETE" and path == "/v1/box":
            known = self.boxes.get(box)
            if known and known["auth"] != hashlib.sha256(("relay|" + auth).encode()).hexdigest():
                return 401, {"error": "auth"}
            self.boxes.pop(box, None)
            self.gone.add(gone_id)
            return 200, {"ok": True}
        if gone_id in self.gone:
            return 410, {"error": "gone"}
        auth_hash = hashlib.sha256(("relay|" + auth).encode()).hexdigest()
        known = self.boxes.get(box)
        if known and known["auth"] != auth_hash:
            return 401, {"error": "auth"}
        if method == "PUT" and path == "/v1/state":
            if not body:
                return 413, {"error": "size"}
            entry = self.boxes.setdefault(box, {"auth": auth_hash, "v": 0})
            entry["state"], entry["v"] = body, entry["v"] + 1
            return 200, {"ok": True}
        if method == "GET" and path.startswith("/v1/state"):
            if not known or "state" not in known:
                return 404, {"error": "empty"}
            return 200, {"v": known["v"], "body": known["state"]}
        if not known:
            return 404, {"error": "no box"}
        if method == "POST" and path == "/v1/push/notify":
            json.loads(body)
            return 200, {"ok": True}
        return 404, {"error": "not found"}

    def pair(self, method, path, body):
        if method == "POST" and path == "/v1/pair/start":
            d = json.loads(body)
            if d["code"] in self.pairs:
                return 409, {"error": "in use"}
            self.pairs[d["code"]] = {"phone": d["pub"]}
            return 200, {"ok": True}
        if method == "POST" and path == "/v1/pair/join":
            d = json.loads(body)
            p = self.pairs.get(d.get("code"))
            if not re.match(r"^\d{6}$", d.get("code", "")) or not p or "computer" in p:
                return 404, {"error": "unknown code"}
            p["computer"], p["name"] = d["pub"], d.get("name", "")
            return 200, {"pub": p["phone"]}
        m = re.match(r"^/v1/pair/(\d{6})$", path)
        if method == "GET" and m:
            p = self.pairs.get(m.group(1))
            if not p:
                return 404, {"error": "unknown code"}
            if "computer" not in p:
                return 200, {"waiting": True}
            del self.pairs[m.group(1)]
            return 200, {"pub": p["computer"], "name": p["name"]}
        return 404, {"error": "not found"}

    def take(self):
        with self.lock:
            out, self.requests = self.requests, []
        return out


class Silent:
    """Accepts connections and never answers: for the 3-second timeout test."""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.url = "http://127.0.0.1:%d" % self.sock.getsockname()[1]
        self.held = []
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                conn, _ = self.sock.accept()
                self.held.append(conn)
            except OSError:
                return
