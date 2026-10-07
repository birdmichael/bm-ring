# bm-ring

Personal fork of [perezjuanj/OpenCircuit](https://github.com/perezjuanj/OpenCircuit)
(upstream base: `63e2796`, Oct 2026) for a RingConn Gen 3 ring.

Upstream is an iOS app that reads RingConn rings over BLE and mirrors data to
Apple Health. This fork keeps all of that and adds:

1. **Push-to-Vibrate** — the app receives a push from your own relay server
   (`push-server/`) and buzzes the Gen 3 ring. iOS exposes no system
   notifications to apps, so this is the way in.
2. **Apple as source of truth** — sleep is read from Apple Health (real staged
   sleep from Apple Watch), blood pressure trends read real cuff readings from
   Apple Health. No PPG-model estimates.
3. **Battery-friendly keepalive** — push-triggered background sync
   (`{"sync": true}`) and significant-location-change wakes; no continuous
   background location.
4. **Apple Watch coexistence** — steps / active energy / sleep are written only
   for intervals the Watch didn't already cover (per-interval, not per-day).
5. **CI** — `.github/workflows/ios-build.yml` builds on every push.

See `docs/PUSH_VIBRATION.md` and `push-server/README.md` for the push setup.

License: upstream is PolyForm Noncommercial 1.0.0 — personal/research use OK,
commercial use restricted. This fork inherits it.

