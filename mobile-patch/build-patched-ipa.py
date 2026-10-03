#!/usr/bin/env python3
"""build-patched-ipa.py - byte-patch the Vanish mobile IPA so no
spoof-session verdict can block a session or auto-stop it, and the
pro-access flag is forced true at decode.

Usage:
    python3 build-patched-ipa.py <source.ipa> [output.ipa]

The source IPA is the stock Vanish.ipa (the same payload the official
installer ships - take it from your own copy of the installer's
Contents/Resources/vanish-ipa/ directory). The output IPA is signed and
installed over the existing app with any sideloading tool that speaks
the Vanish desktop sideloader's flow, or the bundled install-driver.js.

Patch set (5 words, same length, in-place, verified before writing):
  P2a/P2b  bl enforceSpoofDenial          -> NOP  (deny-block dead)
  P3a/P3b  bl scheduleRewardExpiryCheck  -> NOP  (session killswitch dead)
  P4       bl bridgeObjectRelease (redundant, right before the
           Access.pro store) -> movz w27, #1 (access.pro = true on every
           entitlement decode - Saved Places / Location Lock open)

Offsets are for Vanish 3.3.0 (arm64). The script verifies each original
word before patching and aborts on any mismatch - if a future version
moves the code, it refuses to guess.
"""
import struct
import sys
import shutil
import zipfile
import os
import tempfile

PATCHES = [
    # (vaddr, expected original word, replacement word)
    (0x100189874, 0x94000636, 0xD503201F),  # bl enforceSpoofDenial (resume3)
    (0x10018A2FC, 0x94000394, 0xD503201F),  # bl enforceSpoofDenial (resume5)
    (0x100189F84, 0x94000390, 0xD503201F),  # bl scheduleRewardExpiryCheck (r3)
    (0x10018AA0C, 0x940000EE, 0xD503201F),  # bl scheduleRewardExpiryCheck (r5)
    (0x10010C3F4, 0x942354C2, 0x5280003B),  # bl release -> movz w27,#1 (pro=1)
]
TEXT_BASE = 0x100000000
BIN_REL = "Payload/StikDebug.app/StikDebug"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "Vanish-patched.ipa"
    if not os.path.exists(src):
        sys.exit("source IPA not found: %s" % src)

    work = tempfile.mkdtemp(prefix="vanish-patch-")
    try:
        with zipfile.ZipFile(src) as z:
            z.extractall(work)
        binpath = os.path.join(work, BIN_REL)
        data = bytearray(open(binpath, "rb").read())
        for vaddr, expected, repl in PATCHES:
            off = vaddr - TEXT_BASE
            orig = struct.unpack_from("<I", data, off)[0]
            if orig != expected:
                sys.exit(
                    "MISMATCH at %s (file 0x%x): expected 0x%08x, found "
                    "0x%08x - this IPA is not the expected Vanish 3.3.0 "
                    "arm64 build; aborting without writing anything."
                    % (hex(vaddr), off, expected, orig)
                )
            struct.pack_into("<I", data, off, repl)
            print("patched %s: 0x%08x -> 0x%08x" % (hex(vaddr), expected, repl))
        open(binpath, "wb").write(data)

        if os.path.exists(out):
            os.remove(out)
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for root, _, files in os.walk(work):
                for f in sorted(files):
                    full = os.path.join(root, f)
                    rel = os.path.relpath(full, work)
                    if rel == BIN_REL or rel.startswith("Payload/"):
                        z.write(full, rel)
        # verification: reread the patched words from the output IPA
        with zipfile.ZipFile(out) as z:
            blob = z.read(BIN_REL)
        for vaddr, _, repl in PATCHES:
            w = struct.unpack_from("<I", blob, vaddr - TEXT_BASE)[0]
            assert w == repl, "verify failed at %s" % hex(vaddr)
        print("wrote %s (%d bytes)" % (out, os.path.getsize(out)))
        print("verify: all patched sites read back as expected - OK")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
