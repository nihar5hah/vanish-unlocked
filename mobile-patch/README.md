# Vanish Mobile — five-byte patch

Unlocks the Vanish iOS GPS spoofer: no deny path, no session auto-stop, and
every pro-gated feature (Saved Places, Location Lock) opens.

## Build

```bash
# source = the stock Vanish.ipa from your own copy of the desktop installer
python3 build-patched-ipa.py /path/to/Vanish.ipa Vanish-patched.ipa
```

The patcher verifies each original instruction word before patching and
aborts on any mismatch (wrong version / moved code). Offsets are for
Vanish 3.3.0 arm64.

## Install (either route)

**A. The desktop app's own flow** (simplest): place the patched IPA at
`/Applications/Vanish.app/Contents/Resources/vanish-ipa/Vanish.ipa`, open the
desktop app, use "Install Vanish Mobile" (Apple ID login + 2FA in its UI),
then restore the stock IPA at that path. The sideloader signs the patched
payload for your free Personal Team and installs it **over** the existing
app — data, keychain session and pairing preserved.

**B. The direct driver** (no UI):

```bash
node install-driver.js Vanish-patched.ipa
# flags: --helper <path> --data-dir <dir>
# env:   VANISH_APPLE_ID / VANISH_APPLE_PW (or interactive prompts + 2FA)
```

The driver speaks the sideloader helper's JSON-lines protocol directly
(recovered from the desktop bridge): `status` → `login` → `two_factor_code`
→ `max_certs_response` (if the free team hits Apple's cert limit) →
`list_devices` → `select_device` → `install_sidestore {path}`.

## The five sites (details in the analysis docs)

| ID | vaddr | before | after |
|----|-------|--------|-------|
| P2a | `0x100189874` | `bl enforceSpoofDenial` (resume #3) | NOP |
| P2b | `0x10018a2fc` | `bl enforceSpoofDenial` (resume #5) | NOP |
| P3a | `0x100189f84` | `bl scheduleRewardExpiryCheck` (#3) | NOP |
| P3b | `0x10018aa0c` | `bl scheduleRewardExpiryCheck` (#5) | NOP |
| P4 | `0x10010c3f4` | `bl bridgeObjectRelease` (redundant) | `movz w27, #1` |

P2/P3 kill the two client-side enforcement points (the deny-block and the
session killswitch). P4 forces `VanishMobileState.Access.pro = true` at
every entitlement decode by overwriting the register feeding the `pro`
store.

## Verify on device

1. Spoof anywhere — starts fine.
2. Let the free 30-minute window run out — the session **keeps running**
   (killswitch dead).
3. Spoof again after the daily cap is spent — the app logs the denial and
   **spoofs anyway** (no paywall).
4. Open Saved Places / Location Lock — both open (pro forced).
5. The app's own **Refresh** (7-day re-sign) re-signs the patched build
   in place — the patch survives every refresh; updates never
   auto-install (the update flow is a nag + website link only).
