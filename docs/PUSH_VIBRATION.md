# Push-to-Vibrate — setup guide (bm-ring fork)

Buzz your RingConn Gen 3 from anything that can do an HTTP POST: server alerts,
Home Assistant, cron jobs, CI pipelines. iOS gives third-party apps no access to
*system* notifications, so this takes the other road: **your own server sends your
own app a push, and the app buzzes the ring.** Your events, your rules, no cloud
account anywhere.

## What you need

1. **Apple Developer Program** ($99/yr) — APNs requires it. (You likely already
   need it: HealthKit write on a sideloaded dev build needs the paid entitlement too.)
2. A **push key** (.p8) — one per team, works for all your apps.
3. An **always-on machine** for the relay — a Mac mini, Raspberry Pi, VPS, anything
   with Python 3.10+.
4. This app built and installed with **your** bundle id and **your** push key's team.

## Step 1 — Apple push key

1. Go to developer.apple.com → Certificates, Identifiers & Profiles → Keys.
2. Create a key, enable **Apple Push Notifications service (APNs)**, download the `.p8`
   (you only get one download — keep it safe, it can push to all your apps).
3. Note the **Key ID** and your **Team ID** (Membership page).

## Step 2 — App side

1. Open `ios/` in Xcode (via `project.yml` + XcodeGen, per the main README).
2. Set the target's **bundle id** and **team** to yours.
3. Make sure the App ID has the **Push Notifications** capability enabled
   (Xcode → Signing & Capabilities → + Capability → Push Notifications).
4. Build & install on your iPhone (this fork adds the `remote-notification`
   background mode to Info.plist already — nothing else to flip).
5. On the phone: Device → **Push vibrations** → enable it, pick a default pattern.
6. Tap **Copy full token** — you'll paste this into the server config.

The token changes if you reinstall the app. If pushes suddenly stop working after
a reinstall, this is the first thing to check.

## Step 3 — Relay server

```bash
cd push-server
pip install -r requirements.txt
cp config.example.json config.json
# fill in team_id, key_id, p8_path, bundle_id, device_token
python server.py
```

Test from the same machine:

```bash
curl -X POST localhost:8902/buzz -H 'Content-Type: application/json' \
  -d '{"pattern": "notification", "count": 2}'
```

Ring should buzz within seconds. If it doesn't, check in order:
1. App's Push vibrations screen → last outcome (tells you if the push arrived
   and why the buzz was blocked: ring unreachable / on charger / busy).
2. Server stdout — APNs rejections print the status code (`400` = bad payload,
   `403` = bad key/topic, `410` = device token dead).
3. `GET localhost:8902/health` — is the server even up?

## Step 4 — point the world at it

`POST /buzz` accepts:

| field | values | default |
|---|---|---|
| `pattern` | `notification` (triple pulse) · `long` (single buzz) | your default |
| `count` | 1–5 | your default |
| `title` / `body` | adds a visible banner alongside the buzz | none (silent) |

Examples:

```bash
# Home Assistant automation → REST command
# Uptime Kuma → webhook URL http://pi:8902/buzz?secret=XXX with body:
{"pattern": "long", "count": 5, "title": "PROD", "body": "api latency p99 > 2s"}

# cron: stand up every hour, 9–18
0 9-18 * * * curl -s -X POST localhost:8902/buzz -d '{"pattern":"notification","count":1}'
```

## Honest limits

- **Silent pushes are best-effort.** Apple throttles apps that fire them constantly.
  This is for events that matter, not a per-minute heartbeat. If you need
  guaranteed delivery, add `title`/`body` — alert pushes are prioritized higher,
  at the cost of a banner on screen.
- **~30 s background budget.** Enough to reconnect BLE and fire one command if the
  ring is nearby; not enough to hunt for a ring across the house.
- **No delivery receipt.** `8b 00 8b` means the ring accepted the frame, not that
  anyone felt it. The settings screen records accepted/blocked/missed — never "felt".
- **Ring must be Gen 3** (the only model with a motor), nearby, off the charger,
  and not mid-sync.
- **One device token per install.** Reinstalls rotate it.

## What this fork added vs upstream OpenCircuit

Upstream already had the vibrate command, Find My Ring, CSV export, and on-demand
measurement (ringlink's headline features are all there — this fork didn't need to
port them). What's new here:

- `PushVibrationController` — push → BLE buzz routing, reconnect-with-budget,
  outcome recording, plus push-triggered background sync (`{"sync": true}`)
- `PushVibrationSettingsView` — enable/pattern/count, token copy, status, test buzz
- `AppDelegate` — APNs registration + silent-push handler
- `Info.plist` — `remote-notification` background mode, location usage descriptions
- `AppleSleepReader` + `AppleSleepRow` — Apple Health measured sleep (Watch staging
  when present) shown on the sleep card, preferred over ring inference
- `BloodPressureReader` + `BloodPressureTrendView` — real cuff readings from Apple
  Health, trended (Trends tab). Never modelled.
- `LocationWakeSync` + `KeepaliveSettingsView` — battery-friendly keepalive: the
  Tesla trick at 1% of the cost (significant-change monitoring, not continuous
  location), layered over push pings + the existing BGTask/BT-restoration wakes
- `push-server/` — personal APNs relay with webhook endpoint (`/buzz` → buzz and/or sync)
- This doc

## Sync keepalive — the full picture

iOS decides when background work runs; no app can fully control it. This fork
layers every battery-cheap wake source so at least one fires often:

| Wake source | Cost | Fires when |
|---|---|---|
| Silent-push ping (`{"sync": true}`) | ~0 idle; one 20 s drain per ping | your cron decides (e.g. every 30 min) |
| Significant-change location | ~0 (cell radio already on) | you move ~500 m+ (throttled: 30 min) |
| Bluetooth state restoration | ~0 | ring has traffic / comes in range |
| BGAppRefresh / BGProcessingTask | ~0 | iOS feels like it |
| Foreground open | — | you open the app |

What we deliberately DON'T do: continuous background location (Tesla's actual
approach — real battery cost, and wrong tradeoff for health sync that doesn't
need car-key latency).

Not ported (deliberately): Android's notification-listener buzz — impossible on iOS
(system notifications are off-limits to third-party apps); multi-ring — upstream is
architecturally one-device-at-a-time, a bigger surgery than this feature needed.
