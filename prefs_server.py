#!/usr/bin/env python3
"""The proxy's preferences, as a page in the browser: http://localhost:8750

Reads and writes the prefs file midiproxy watches. The proxy re-reads it within half a
second of a change, so the platter can be retuned while you scratch on it -- no restart,
and nothing to re-select in djay. The page also carries a live jog test, which reads the
deck and the proxy straight over Web MIDI (Chrome) and needs nothing from here.

Listens on 127.0.0.1 only. Writes must come from the page itself: a JSON body and a
localhost Host header, so another website open in the same browser cannot drive it.

    ./prefs_server.py [--port 8750] [--prefs <path>] [--open]
"""
import argparse, json, os, re, subprocess, sys, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAGE = HERE / "web" / "index.html"
PREFS = Path.home() / "Library/Application Support/SC5000M Proxy/prefs.json"
LOG = Path("/tmp/midiproxy.log")
AGENT = f"gui/{os.getuid()}/com.sc5000.midiproxy"

# Every preference midiproxy reads from the file. The defaults mirror midiproxy.swift's
# own -- keep the two in step, as with padModeBase and build_mapping.py.
SCHEMA = {
    "decks":         {"type": "int",   "default": 2,       "min": 2,   "max": 4},
    "scratchEngine": {"type": "enum",  "default": "touch", "choices": ["touch", "notouch"]},
    "scratchAccel":  {"type": "bool",  "default": True},
    "coastRelease":  {"type": "bool",  "default": True},
    "whilePlaying":  {"type": "enum",  "default": "nudge", "choices": ["nudge", "scratch", "ignore"]},
    "scratchScale":  {"type": "float", "default": 2.4,     "min": 1.0, "max": 8.0},
    "scratchIdleMs": {"type": "int",   "default": 50,      "min": 10,  "max": 300},
    "scratchEnter":  {"type": "int",   "default": 4,       "min": 1,   "max": 12},
    "jogDivisor":    {"type": "int",   "default": 8,       "min": 1,   "max": 32},
    "platterGapMs":  {"type": "int",   "default": 0,       "min": 0,   "max": 20},
    "motor":         {"type": "bool",  "default": False},
}
DEFAULTS = {k: s["default"] for k, s in SCHEMA.items()}


def clean(key, value):
    """One value, coerced to its schema and clamped. ValueError if it cannot be."""
    s = SCHEMA.get(key)
    if s is None:
        raise ValueError(f"unknown preference {key!r}")
    t = s["type"]
    if t == "bool":
        if not isinstance(value, bool):
            raise ValueError(f"{key} must be true or false")
        return value
    if t == "enum":
        if value not in s["choices"]:
            raise ValueError(f"{key} must be one of {', '.join(s['choices'])}")
        return value
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{key} must be a number")
    v = min(s["max"], max(s["min"], value))
    return int(round(v)) if t == "int" else round(float(v), 2)


def read_prefs():
    """Defaults, overlaid with whatever in the file is still valid."""
    prefs = dict(DEFAULTS)
    try:
        stored = json.loads(PREFS.read_text())
    except (OSError, ValueError):
        return prefs
    for k, v in stored.items() if isinstance(stored, dict) else ():
        try:
            prefs[k] = clean(k, v)
        except ValueError:
            pass
    return prefs


def write_prefs(prefs):
    # Replace, never rewrite in place: the proxy polls the file and must not catch it
    # half-written.
    PREFS.parent.mkdir(parents=True, exist_ok=True)
    tmp = PREFS.with_name(PREFS.name + ".tmp")
    tmp.write_text(json.dumps(prefs, indent=2) + "\n")
    os.replace(tmp, PREFS)


def log_tail(n=40):
    try:
        with open(LOG, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 32768))
            return f.read().decode("utf-8", "replace").splitlines()[-n:]
    except OSError:
        return []


def status():
    r = subprocess.run(["launchctl", "print", AGENT], capture_output=True, text=True)
    if r.returncode == 0:
        state = re.search(r"^\s*state = (\S+)", r.stdout, re.M)
        pid = re.search(r"^\s*pid = (\d+)", r.stdout, re.M)
        agent = {"installed": True, "state": state.group(1) if state else "unknown",
                 "pid": int(pid.group(1)) if pid else None}
    else:
        agent = {"installed": False, "state": "not installed", "pid": None}
    log = log_tail()
    # The proxy's own last word on the deck: it prints "in   : <name>" once connected
    # and "waiting for ..." while the deck is off.
    deck = None
    for line in reversed(log):
        if line.startswith("in   :"):
            deck = {"connected": True, "name": line[6:].strip()}
            break
        if line.startswith(("waiting for", "deck disconnected")):
            deck = {"connected": False, "name": None}
            break
    return {"agent": agent, "deck": deck, "log": log}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def trusted(self):
        """Only the page itself may write. A cross-site form cannot send a JSON body
        without a preflight this server never answers, and checking Host shuts out a
        rebound DNS name pointing at 127.0.0.1."""
        host = (self.headers.get("Host") or "").split(":")[0]
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        return host in ("localhost", "127.0.0.1") and ctype == "application/json"

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.send(200, PAGE.read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/api/prefs":
            self.send(200, {"prefs": read_prefs(), "schema": SCHEMA, "path": str(PREFS)})
        elif self.path == "/api/status":
            self.send(200, status())
        else:
            self.send(404, {"error": "not found"})

    def do_PUT(self):
        if self.path != "/api/prefs":
            return self.send(404, {"error": "not found"})
        if not self.trusted():
            return self.send(403, {"error": "forbidden"})
        try:
            changes = self.body()
            if not isinstance(changes, dict):
                raise ValueError("expected an object of preferences")
            prefs = read_prefs()
            prefs.update({k: clean(k, v) for k, v in changes.items()})
        except ValueError as e:
            return self.send(400, {"error": str(e)})
        write_prefs(prefs)
        self.send(200, {"prefs": prefs})

    def do_POST(self):
        if self.path != "/api/restart":
            return self.send(404, {"error": "not found"})
        if not self.trusted():
            return self.send(403, {"error": "forbidden"})
        r = subprocess.run(["launchctl", "kickstart", "-k", AGENT], capture_output=True, text=True)
        if r.returncode:
            return self.send(500, {"error": (r.stderr or r.stdout).strip() or "kickstart failed"})
        self.send(200, {"ok": True})


def main():
    global PREFS
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=8750)
    ap.add_argument("--prefs", type=Path, help="prefs file, as midiproxy --prefs (default: %s)" % PREFS)
    ap.add_argument("--open", action="store_true", help="open the page in the browser")
    args = ap.parse_args()
    PREFS = args.prefs or PREFS
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://localhost:{args.port}"
    print(f"prefs page  {url}\nprefs file  {PREFS}", flush=True)
    if args.open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
