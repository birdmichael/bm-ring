# push-server — your personal buzz relay

Sends a silent Apple push to your phone; the bm-ring app buzzes your Gen 3 ring
on arrival. You decide what deserves a buzz by pointing webhooks at it.

## Quick start

```bash
pip install -r requirements.txt
cp config.example.json config.json
# edit config.json (see below)
python server.py
```

Test it:

```bash
curl -X POST localhost:8902/buzz -H 'Content-Type: application/json' \
  -d '{"pattern": "notification", "count": 2}'
```

Your ring should buzz twice within a few seconds (app must have
*Push vibrations* enabled, ring nearby and off the charger).

With a banner as well as a buzz:

```bash
curl -X POST localhost:8902/buzz -H 'Content-Type: application/json' \
  -d '{"pattern": "long", "count": 3, "title": "Server", "body": "disk 95% full"}'
```

## config.json fields

| key | where to get it |
|---|---|
| `team_id` | Apple Developer portal → Membership |
| `key_id` | Developer portal → Keys → your push key |
| `p8_path` | The `.p8` file downloaded when you created the key |
| `bundle_id` | Your app's bundle id (Xcode target) |
| `device_token` | In the app: Device → Push vibrations → copy token |
| `webhook_secret` | Optional. If set, callers must send it as `X-Webhook-Secret` header or `?secret=` |
| `host` / `port` | Bind address. Keep `127.0.0.1` unless you know why not |

## Wiring ideas

- **Home Assistant**: automation → RESTful command POST to `/buzz`
- **Uptime Kuma / healthchecks**: webhook on DOWN → `{"pattern":"long","count":5}`
- **cron**: `curl` on a schedule (stand up, drink water, market open…)
- **Email**: filter → forward to a tiny script → POST
- **CI**: build failed → buzz; build fixed → single gentle buzz

Severity convention suggestion: `notification`×1 = info, `notification`×3 = warning,
`long`×5 = drop everything.

## Security notes

- `/buzz` with no secret is an open buzzer. Set `webhook_secret`, or bind to
  localhost and reach it via Tailscale/WireGuard.
- The `.p8` key can send pushes to ALL your apps — guard it like a password.
- APNs is best-effort. Apple throttles silent pushes that fire too often;
  this is for events that matter, not a per-minute heartbeat.

## How it works

Token-based APNs auth (JWT, ES256, refreshed every 50 min) over HTTP/2.
Payload is `{"aps": {"content-available": 1}, "buzz": {"pattern","count"}}` —
a silent push, so nothing appears on screen unless you also pass title/body.
The app's `PushVibrationController` wakes (~30 s budget), reconnects BLE if
needed, and fires the motor command `0b 03 <pattern> 64 00`.
