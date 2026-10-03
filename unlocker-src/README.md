# Vanish Unlocker (the out-of-the-box package)

A single native macOS app — no dependencies, no terminal, no node, no python.
Download the **Vanish Unlocker.zip** from this repository's [releases](../../releases),
unzip, and open the app.

> First launch: the app is ad-hoc signed, so macOS shows the "unidentified
> developer" note once — **right-click → Open → Open** (once), standard for
> any unsigned app. Requires the Vanish desktop app installed at
> `/Applications/Vanish.app` (the unlocker drives its sideloader helper and
> reads the stock mobile IPA from it).

## What the two buttons do

**Open Vanish (Mac) — paid**
Starts the embedded entitlement server on `127.0.0.1:8787` (serving tier
`paid`), launches Vanish with `VANISH_API_URL` pointed at it, and stops the
server when Vanish quits. Nothing on disk changes — launch Vanish normally
again and everything is stock.

**Unlock the iPhone app**
One button, one Apple ID entry, done:
1. patches the stock `Vanish.ipa` with the embedded five-word patcher
   (verify-then-write: it reads each original instruction word first and
   refuses to guess if the build doesn't match Vanish 3.3.0 arm64)
2. drives the sideloader helper (the same one the desktop app uses) over its
   JSON-lines protocol: Apple ID login → 2FA if asked → device select →
   sign for your free Personal Team → install **over** the existing app
   (data, keychain session and pairing preserved)
3. the installed app has no deny path, no session auto-stop, and
   `access.pro = true` (Saved Places / Location Lock open)

The patched build is self-perpetuating: the phone app's own 7-day Refresh
re-signs the installed (patched) binary in place, and app updates never
auto-install (the update flow is a version-check nag that links to the
website).

## Build it yourself

```bash
swiftc -parse-as-library -O -framework SwiftUI -framework Network \
       -framework AppKit -o VanishUnlocker unlocker.swift
```

(source is this single file; the release zip is exactly this build, ad-hoc
signed with `codesign -s - --force --timestamp=none`)

## Self-tests built into the binary

```bash
UNLOCKER_HEADLESS_TEST=1 ./Vanish\ Unlocker.app/Contents/MacOS/VanishUnlocker
# starts the embedded server, probes entitlement-get/trial-bootstrap/track-event,
# prints PASS/FAIL, exits

UNLOCKER_PATCH_TEST=1 ./Vanish\ Unlocker.app/Contents/MacOS/VanishUnlocker
# patches the stock IPA end-to-end (verify-then-write), prints PASS/FAIL
```

Both PASS on the release build. The Apple-ID install leg is interactive by
design — that's the one step only a human can do (Apple's requirement, not
the tool's).
