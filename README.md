# vanish-unlocked

Tools + analysis for unlocking **Vanish** (a commercial iPhone GPS spoofer:
an Electron desktop app that signs and installs an iOS app which spoofs
location over an on-device RemotePairing tunnel) on your own machines.

Two unlock routes, both fully worked and verified on real hardware:

- **desktop-redirect/** — the macOS app, unlocked with **zero bytes
  modified**: a ~90-line local entitlement server plus one environment
  variable. The app itself ships the hook: `VANISH_API_URL` redirects every
  licensing call at launch. Runs any tier you configure (`paid`,
  `trial_full`, …) — also doubles as a reproduction rig for every tier
  state, including blocked/machine-changed.
- **mobile-patch/** — the iOS app, unlocked with **five same-length
  instruction words**: the deny-block and the session killswitch NOP'd, and
  the pro-access flag forced true at decode. The patcher verifies every
  original word before touching anything and aborts on mismatch. The
  patched build is self-perpetuating: the app's 7-day self-refresh
  re-signs the installed (patched) binary in place, and updates never
  auto-install.

## Quick start

**Easiest (out of the box):** download **`Vanish Unlocker.zip`** from
[releases](../../releases) — one native app, zero dependencies, two buttons:

- **Open Vanish (Mac) — paid** — launches Vanish fully paid; stops its
  embedded server when Vanish quits; nothing persists
- **Unlock the iPhone app** — patches the stock IPA with the embedded
  patcher and drives the sideloader: your Apple ID once (+2FA if asked),
  and the phone app installs unlocked over the existing one

Requires the Vanish desktop app installed (the unlocker drives its
sideloader helper and reads the stock mobile IPA from it). First launch of
the unlocker: right-click → Open (once) — it's ad-hoc signed.

**Manual routes** (the same machinery as scripts):

### Desktop

```bash
cd desktop-redirect
node fake-backend.js &                      # serves tier "paid" on 127.0.0.1:8787
VANISH_API_URL=http://127.0.0.1:8787 /Applications/Vanish.app/Contents/MacOS/Vanish
```

The app's console shows `[entitlement] fetched — tier: paid`; routes,
realism and teleport all pass. Launch normally again and everything is
stock — nothing persisted on the app side. Other tiers:
`VANISH_FAKE_TIER=trial_full node fake-backend.js` (or `none`, `expired`,
`revoked`, `blocked`).

### Mobile

```bash
cd mobile-patch
python3 build-patched-ipa.py /path/to/stock/Vanish.ipa Vanish-patched.ipa
node install-driver.js Vanish-patched.ipa
# or: use the desktop app's own install flow (see mobile-patch/README.md)
```

## Analysis (why this works)

Full write-ups in `analysis/`:

- **DESKTOP-ANALYSIS.md** — the entitlement model: plaintext
  client-generated identity, an env-overridable backend base, a 5-minute
  unsigned-JSON cache, fail-open `tier:"none"` offline, and gates that only
  block for `expired/revoked/blocked`. Every enforcement decision the
  binary makes is local.
- **MOBILE-ANALYSIS.md** — the decompiled spoof-verdict switch (exactly four
  client branches; enforcement is exactly two functions with two call sites
  each), the `Access.pro` decode, the plaintext legacy license cache, and
  the self-refresh pipeline (27.5k lines of disassembly, zero network
  calls — pure self-copy, so a patched build re-signs itself forever).

The recurring shape, stated once plainly: **the server says whatever it
says; what the client *does about it* is local.** Both routes only change
the local half. No local change touches the backend's records, other
clients, or anyone else's account.

## Repository contents

```
unlocker-src/unlocker.swift       the single-file source of the Unlocker app
unlocker-src/README.md            the Unlocker app: usage, build, self-tests
desktop-redirect/fake-backend.js  the local entitlement server (~90 lines, zero deps)
mobile-patch/build-patched-ipa.py the five-word IPA patcher (verify-then-write)
mobile-patch/install-driver.js    direct driver for the sideloader helper (JSON-lines)
mobile-patch/README.md            install routes (app flow or driver) + verification
analysis/DESKTOP-ANALYSIS.md      full macOS entitlement analysis
analysis/MOBILE-ANALYSIS.md       full iOS licensing + self-refresh analysis
```

The ready-to-use app binary ships as **`Vanish Unlocker.zip`** on the
[releases page](../../releases) (git carries the source; releases carry the
build).

Offsets and wire formats are pinned to Vanish **3.3.0** (desktop + mobile
arm64). Later versions move code; the patcher refuses to guess, and the
redirect route survives version changes until the env hook itself moves.
