# Vanish Mobile (iOS) — Analysis

Target: the Vanish.ipa shipped inside the desktop installer
(`Contents/Resources/vanish-ipa/Vanish.ipa`). Binary:
`Payload/StikDebug.app/StikDebug` — 32.7 MB arm64 Swift, **unstripped**,
unsigned at rest (the desktop sideloader signs it at install). All offsets
reference the stock 3.3.0 build.

## Architecture

SwiftUI app (StikDebug/StikJIT fork). GPS spoofing over an on-device
RemotePairing tunnel (loopback reflector at `10.7.0.1`, dynamic port via
mDNS `_remotepairing._tcp`), DVT LocationSimulation channel, self-refresh
signing stack (Rust FFI: isideload + apple-codesign), Live Activity
extension (no licensing logic anywhere in it).

## The licensing model (recovered)

Two generations ship together:

- **3.x session path** — `VanishAccount`: email + 4-digit code
  (`mobile-auth-request` / `mobile-auth-verify`) → `session_token` in the
  keychain; state refresh (`mobile-entitlement` → `VanishMobileState`
  `{Access, Account, Gates, Reward}`); per-spoof decision
  (`mobile-spoof-session` → `Decision`); ads/reward flow
  (`reward-session-create`).
- **2.x license path (retained)** — `LicenseManager`: license key via
  `mobile-license-resend` / `mobile-license-validate`; cache in
  **plaintext UserDefaults** (`sd_license_cached_valid/plan/expires`,
  `sd_license_last_validation`, `sd_license_grace_period_hours`).

`VanishMobileState.Access = { pro: Bool, pro_source, plan, expires_at }` —
`pro` is a required Bool decoded from the response; every pro-gated UI
(Saved Places, Location Lock, routes surface) reads it.

## The spoof verdict (decompiled)

Spoof tap → `LocationSimulationView.evaluateSpoofSession` (0x10018939c) →
`checkSpoofSession` → server `Decision` → one of exactly four client
branches:

| Branch | String | Behavior |
|---|---|---|
| allowed | `"Spoof session allowed"` | proceed; free_daily mint toast + `scheduleRewardExpiryCheck()` |
| denied (enforced) | `"Spoof session denied ("` + decision + `")"` | **`enforceSpoofDenial(reason)`** — paywall/stop; `reward_required` skips the two-strike grace |
| denied (not enforced) | `"Spoof session observe-denied ("` … `"); not enforced, spoof continues"` | log only, proceed |
| unreachable | `"Spoof session check unreachable; spoof continues (grace)"` | **fail-open** |

Enforcement is exactly **two client functions**: `enforceSpoofDenial`
(0x10018b14c) and `scheduleRewardExpiryCheck` (0x10018adc4, the killswitch
timer that stops a session when the free window ends) — each with exactly
two call sites. The daily cap (30 min/day) counts
`customer OR device` since UTC midnight, minted server-side at spoof start.

## The patch (see ../mobile-patch/)

Five same-length words kill every client-side enforcement and force the pro
flag: the four `bl` calls above → NOP, and the redundant
`bridgeObjectRelease` immediately before the `Access.pro` store →
`movz w27, #1` (pro = true on every decode). After the patch: denied
verdicts log and spoof anyway, sessions never auto-stop, and every
pro-gated feature opens. Verified on device: spoofing, routes, schedule and
Saved Places all run past the free tier.

## The self-refresh (decompiled — the important surprise)

There is **no external IPA source**. The refresh pipeline is pure
self-distribution: `stageCopyOfSelf` copies the installed app →
`packageIPA` → `signedBundleID`/`rewriteBundleID` (derive the real identity)
→ on-device re-sign (`SigningManager.performLogin`/2FA via the Rust core) →
`stageOverAFC` to `/PublicStaging/VanishSelfRefresh.ipa` →
`runUpgrade` (installation_proxy upgrade, data preserved). 27,503 lines of
pipeline disassembly contain zero network calls; the only "update" is a nag
that GETs `mobile-app-version` for a version number and links to the
website. **Consequence: a patched build is self-perpetuating — the 7-day
refresh re-signs it forever, and no update can silently overwrite it.**

## Transport posture

No certificate pinning, no trust delegate, plain `URLSession`, ATS
`NSAllowsArbitraryLoads: true` — a proxy MITM with an installed CA could
serve the mobile backend responses without any patching (the phone-side
equivalent of the desktop env redirect; not needed once the byte patch is
in, since the patch is permanent and standalone).

## Client/server split (plainly)

Server-confirmed: the real subscription rows, sign-ins, `reward_grants`
minting, other clients' views — untouched by any local patch. Client-side:
the verdict dispatch, the strike counter, the killswitch timer, the
pro flag — all local bytes, all patched.
