# Vanish Desktop (macOS) — Analysis

Target: Vanish 3.3.0 (Electron 31.7.7, arm64, Developer-ID signed, notarized,
hardened runtime). Everything below was recovered statically from the shipped
app bundle; offsets reference the stock build.

## Architecture

Electron shell whose entire business logic ships in `app.asar` (minified JS):
device discovery (usbmuxd + `_remotepairing._tcp` mDNS, dynamic port), an
embedded CPython 3.13 + pymobiledevice3 stack that opens a DVT
LocationSimulation channel to the phone, a Rust helper (`VanishSideloader`:
Apple ID auth via GrandSlam/SRP + anisette, Personal-Team cert lifecycle,
IPA signing, pairing injection) and a bundled iOS app that does the actual
GPS spoofing over an on-device tunnel.

## The entitlement model (recovered)

- Identity: `vanish_identity.json` in userData — a UUID `install_id` plus a
  `machine_hash` = sha256(`hostname|platform|cpu-model`)[0:32], **plaintext,
  client-generated, client-trusted**. The persisted value beats re-derivation;
  any 32-hex edit sticks.
- Every licensing call POSTs both strings to
  `${BACKEND_BASE}/<endpoint>` over plain `URLSession`/fetch.
- **`BACKEND_BASE` is environment-overridable at launch** (main.js:3083):
  `process.env.VANISH_API_URL ?? "https://<project>.functions.supabase.co/functions/v1"`.
- Launch: `trial-bootstrap` (409 → machine-changed wall) then
  `entitlement-get` → `{entitlement:{tier,...}}`; cached 5 min; **fail-open to
  `tier:"none"` on any error**.
- Tiers: `none | trial_teleport_only | trial_full | paid | expired | revoked
  | blocked` (+ `reason:"machine_changed"`). Trial issuance and expiry are
  minted server-side; the client never locally expires anything.
- Enforcement (main-process gates): spoof blocks only for
  `{expired, revoked, blocked}`; route additionally blocks
  `trial_teleport_only`; `tier:"none"` (offline / backend blocked) keeps
  teleport AND routes enabled. Renderer `deriveFlags` mirrors the same
  strings for the UI. A blocked-tier transition tears down a live session.
- Backend surface: `trial-bootstrap/-start/-extend`, `entitlement-get`,
  `checkout-status/-create-session`, `pricing-get`,
  `billing-create-portal-session`, `desktop-notice-get/-upgrade-link`,
  `referral-status/-apply/-claim`, `restore-request/-consume`, `sign-out`,
  `track-event`. No auth header, no signature, no pinning; responses are
  unsigned JSON the client trusts verbatim.
- Electron fuses: `EnableEmbeddedAsarIntegrityValidation` + `OnlyLoadAppFromAsar`
  on — asar byte edits require the Info.plist hash update + re-sign;
  `RunAsNode`/`NODE_OPTIONS` off (irrelevant: plain env vars still reach the
  main process, so `VANISH_API_URL` works in the shipped build).

## The client/server split (the point of the whole analysis)

Server-confirmed (untouchable by any local change): the Stripe subscription,
the backend's customer/install/trial rows, machine-binding 409s, other
clients' views. Client-side (fully local): every tier the app acts on, both
gate sites, the downgrade teardown, the identity strings the server binds
with, the fail-open offline mode, the ungated `dev-reset` IPC.

**Every enforcement decision the desktop binary makes is local, fed by one
unsigned JSON response whose host the app itself redirects via a stock
environment variable.**

## Unlock routes (see ../desktop-redirect/)

1. **Redirect (recommended, zero-touch):** run `fake-backend.js`, launch the
   app with `VANISH_API_URL=http://127.0.0.1:8787` — tier `paid` (or any
   tier you configure). Verified end to end: teleport, routes, realism, and
   the focus-refresh all pass against the local server.
2. **Asar patch:** same-length literal corruptions at the gate comparison
   sites (`0x325d66/0x325db3/0x325dce/0x325e1c` route gate,
   `0x326e65/0x326f18/0x326f33` spoof gate), then Info.plist
   `ElectronAsarIntegrity` hash update + ad-hoc re-sign.
3. **Fail-open:** block the backend host; the app degrades to `tier:"none"`
   which still allows teleport + routes.
