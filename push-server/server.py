#!/usr/bin/env python3
"""Push-to-Vibrate relay server for the bm-ring fork of OpenCircuit.

You send it a webhook; it sends your iPhone a silent APNs push; the app buzzes
your Gen 3 ring. Your events, your server, your rules — no third party in the loop.

Setup:
    pip install -r requirements.txt
    cp config.example.json config.json   # then fill in your Apple push key etc.
    python server.py

Then:
    curl -X POST localhost:8902/buzz -H 'Content-Type: application/json' \\
        -d '{"pattern": "notification", "count": 2}'

    # ...or trigger a background sync instead of (or with) a buzz:
    curl -X POST localhost:8902/buzz -H 'Content-Type: application/json' \\
        -d '{"sync": true}'

Wire anything that can do an HTTP POST into /buzz: Home Assistant automations,
Uptime Kuma webhooks, cron + curl, email filters, CI pipelines. Each POST becomes
a buzz (if the app has Push vibrations enabled and the ring is nearby) and/or a
short background sync — a cron pinging {"sync": true} every 30 min is the
battery-friendly keepalive (see the SYNC KEEPALIVE screen in the app).

APNs auth uses token-based auth (.p8 key from the Apple Developer portal):
no certificates to renew yearly, one key works for all your apps.
"""

import json
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

import httpx
import jwt  # PyJWT

APNS_HOST = "https://api.push.apple.com"          # production; sandbox: api.sandbox.push.apple.com
APNS_PORT = 443

_config = None


def load_config(path="config.json"):
    global _config
    if _config is None:
        with open(path) as f:
            _config = json.load(f)
        for k in ("team_id", "key_id", "p8_path", "bundle_id", "device_token"):
            if k not in _config:
                raise SystemExit(f"config.json missing required key: {k}")
    return _config


_provider_token = {"token": None, "issued_at": 0}


def provider_token(cfg):
    # Provider tokens are valid for 60 min; refresh at 50.
    now = time.time()
    if _provider_token["token"] and now - _provider_token["issued_at"] < 3000:
        return _provider_token["token"]
    with open(cfg["p8_path"]) as f:
        key = f.read()
    token = jwt.encode(
        {"iss": cfg["team_id"], "iat": int(now)},
        key,
        algorithm="ES256",
        headers={"kid": cfg["key_id"]},
    )
    _provider_token.update(token=token, issued_at=now)
    return token


def send_push(cfg, pattern="notification", count=1, title=None, body=None, sync=False):
    """Send one push. Silent by default (buzz only); pass title/body for a banner too.
    sync=True asks the app to run a short background sync on wake (no buzz unless
    pattern/count say so — {"sync": true} alone syncs silently)."""
    if pattern not in ("notification", "long"):
        raise ValueError("pattern must be 'notification' or 'long'")
    count = max(1, min(5, int(count)))

    aps = {"content-available": 1}
    if title or body:
        aps["alert"] = {"title": title or "Ring buzz", "body": body or ""}
        aps["sound"] = "default"
    payload = {"aps": aps, "buzz": {"pattern": pattern, "count": count}}
    if sync:
        payload["sync"] = True

    url = f"{APNS_HOST}:{APNS_PORT}/3/device/{cfg['device_token']}"
    headers = {
        "authorization": f"bearer {provider_token(cfg)}",
        "apns-topic": cfg["bundle_id"],   # silent pushes: bare bundle id, no .voip
        "apns-push-type": "background" if "alert" not in aps else "alert",
        "apns-priority": "5",
    }
    # NOTE: apns-priority 5 (not 10) for background pushes — 10 risks throttling.
    with httpx.Client(http2=True) as client:
        r = client.post(url, headers=headers, json=payload, timeout=15)
    if r.status_code != 200:
        raise RuntimeError(f"APNs rejected: {r.status_code} {r.text}")
    return r.headers.get("apns-id")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # quiet; stdout is for real errors

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"ok": True})
        return self._json(404, {"error": "use POST /buzz"})

    def do_POST(self):
        cfg = load_config()
        if self.path == "/buzz":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length) or b"{}")
            except Exception:
                return self._json(400, {"error": "invalid JSON"})
            # Optional shared secret: set "webhook_secret" in config.json to require it.
            secret = cfg.get("webhook_secret")
            if secret:
                qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                provided = self.headers.get("X-Webhook-Secret") or qs.get("secret", [None])[0]
                if provided != secret:
                    return self._json(403, {"error": "bad secret"})
            try:
                body = body or {}
                apns_id = send_push(
                    cfg,
                    pattern=body.get("pattern", "notification"),
                    count=body.get("count", 1),
                    title=body.get("title"),
                    body=body.get("body"),
                    sync=bool(body.get("sync", False)),
                )
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            except RuntimeError as e:
                return self._json(502, {"error": str(e)})
            return self._json(200, {"ok": True, "apns_id": apns_id})
        return self._json(404, {"error": "use POST /buzz"})


if __name__ == "__main__":
    cfg = load_config()
    port = int(cfg.get("port", 8902))
    # Bind localhost by default — put it behind a reverse proxy / Tailscale if your
    # event sources live elsewhere. Do NOT expose an unauthenticated /buzz to the internet.
    host = cfg.get("host", "127.0.0.1")
    print(f"push relay listening on {host}:{port}  →  POST /buzz")
    print("example: curl -X POST localhost:8902/buzz -d '{\"pattern\":\"long\",\"count\":3}'")
    HTTPServer((host, port), Handler).serve_forever()
