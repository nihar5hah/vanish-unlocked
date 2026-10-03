#!/usr/bin/env node
// install-driver.js - drive the Vanish desktop sideloader helper directly
// (JSON-lines protocol) to sign + install a patched Vanish.ipa with a free
// Apple Personal Team, over the existing app (data preserved).
//
// Usage:
//   node install-driver.js <patched.ipa> [--helper <path>] [--data-dir <dir>]
//
// Defaults:
//   --helper    /Applications/Vanish.app/Contents/Resources/sideloader/VanishSideloader
//   --data-dir  ~/Library/Application Support/Vanish/sideloader   (reuses the
//               desktop app's cached anisette/cert material + RPPairing)
//
// Apple ID + password + 2FA are prompted interactively when needed; nothing
// is stored by this script. The alternative to this driver is the desktop
// app's own UI: place the patched IPA at
// Contents/Resources/vanish-ipa/Vanish.ipa inside the desktop app bundle,
// use its "Install Vanish Mobile" flow, then restore the stock IPA.
//
// Protocol (recovered from the desktop app's bridge):
//   stdin : {"id":N,"cmd":...,...args}\n
//   stdout: {"id":N,"ok":bool,"data":...,"error":{type,message}}\n
//           or {"event":"2fa_required"|"max_certs_reached"|"step"|
//                "log"|"install_progress"|"helper_lost", ...}
"use strict";

const { spawn } = require("child_process");
const readline = require("readline");
const path = require("path");
const os = require("os");

const argv = process.argv.slice(2);
const flags = {};
const positional = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith("--")) flags[argv[i].slice(2)] = argv[++i];
  else positional.push(argv[i]);
}

const IPA = positional[0];
const HELPER =
  flags.helper ||
  "/Applications/Vanish.app/Contents/Resources/sideloader/VanishSideloader";
const DATA_DIR =
  flags["data-dir"] ||
  path.join(os.homedir(), "Library/Application Support/Vanish/sideloader");

if (!IPA) {
  console.error("usage: node install-driver.js <patched.ipa> [--helper p] [--data-dir d]");
  process.exit(2);
}
if (!require("fs").existsSync(HELPER)) {
  console.error("sideloader helper not found at %s (pass --helper)", HELPER);
  process.exit(2);
}

const child = spawn(HELPER, ["--data-dir", DATA_DIR, "--temp-dir", os.tmpdir()], {
  stdio: ["pipe", "pipe", "pipe"],
});
let nextId = 1;
const pending = new Map();

child.stdout.setEncoding("utf8");
child.stderr.pipe(process.stderr);
let buf = "";
child.stdout.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (line) handleLine(line);
  }
});

function handleLine(line) {
  let msg;
  try { msg = JSON.parse(line); } catch { console.log("[helper-raw]", line); return; }
  if (typeof msg.event === "string") return onEvent(msg);
  if (typeof msg.id === "number" && pending.has(msg.id)) {
    const p = pending.get(msg.id);
    pending.delete(msg.id);
    clearTimeout(p.timer);
    p.resolve(msg);
  }
}

function cmd(name, args = {}, timeoutMs = 600000) {
  return new Promise((resolve) => {
    const id = nextId++;
    const timer = setTimeout(() => {
      if (pending.delete(id)) resolve({ ok: false, timeout: true, cmd: name });
    }, timeoutMs);
    pending.set(id, { resolve, timer });
    child.stdin.write(JSON.stringify({ id, cmd: name, ...args }) + "\n");
  });
}

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const ask = (q) => new Promise((res) => rl.question(q, res));

async function onEvent(msg) {
  switch (msg.event) {
    case "log":
      console.log("[helper]", msg.message);
      break;
    case "step":
      console.log(`[helper] step ${msg.id}: ${msg.state}${msg.error ? ` (error: ${msg.error.message ?? JSON.stringify(msg.error)})` : ""}`);
      break;
    case "install_progress":
      process.stdout.write(`\r[helper] Installing: ${msg.percent}%   `);
      if (msg.percent >= 100) process.stdout.write("\n");
      break;
    case "2fa_required":
      console.log(`[helper] 2FA required${msg.lastError ? ` (last error: ${msg.lastError})` : ""}`);
      break;
    case "max_certs_reached":
      console.log(`[helper] max certs reached. Existing certs:\n${JSON.stringify(msg.certs, null, 2)}`);
      const serials = (await ask("serials to revoke (comma-separated, Enter to abort)> "))
        .split(",").map((s) => s.trim()).filter(Boolean);
      await cmd("max_certs_response", { serials });
      break;
    case "helper_lost":
      console.error("[helper] helper lost");
      process.exit(1);
  }
}

async function loginFlow() {
  const st = await cmd("status");
  if (st.ok && st.data && st.data.loggedInAs) {
    console.log(`[driver] already logged in as ${st.data.loggedInAs}`);
    return true;
  }
  const email = process.env.VANISH_APPLE_ID || (await ask("Apple ID email> ")).trim();
  const password = process.env.VANISH_APPLE_PW || (await ask("Apple ID password> ")).trim();
  const res = await cmd("login", { email, password });
  if (res.ok) return true;
  if (res.error && res.error.type === "TwoFactorRequired") {
    console.log("[driver] 2FA code sent - enter the code:");
    for (;;) {
      const code = (await ask("2fa> ")).trim();
      const c = await cmd("two_factor_code", { code }, 120000);
      if (c.ok) return true;
      console.log(`[driver] 2fa failed: ${c.error ? c.error.message : "unknown"} - try again`);
      if (!code) return false;
    }
  }
  console.error("[driver] login failed:", res.error ? `${res.error.type}: ${res.error.message}` : res);
  return false;
}

async function main() {
  if (!(await loginFlow())) process.exit(1);
  const dev = await cmd("list_devices");
  if (dev.ok && Array.isArray(dev.data) && dev.data.length) {
    const d = dev.data[0];
    console.log(`[driver] device: ${d.name ?? d.udid} (${d.udid})`);
    const sel = await cmd("select_device", { udid: d.udid });
    if (!sel.ok) console.error("[driver] select_device:", sel.error ?? sel);
  } else {
    console.error("[driver] no devices found - connect the iPhone over USB and unlock it");
    process.exit(1);
  }
  console.log(`[driver] signing + installing ${IPA}`);
  const res = await cmd("install_sidestore", { path: path.resolve(IPA) }, 1200000);
  if (res.ok) {
    console.log("[driver] install OK:", JSON.stringify(res.data ?? null));
  } else {
    console.error("[driver] install failed:", res.error ? `${res.error.type}: ${res.error.message}` : res);
    process.exit(1);
  }
  child.stdin.end();
  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(1); });
