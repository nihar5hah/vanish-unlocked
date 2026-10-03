// fake-backend.js — Vanish 3.3.0 entitlement redirect server (Route B).
// Serves the client-side tier the app acts on. 127.0.0.1 only, zero deps.
// Tier values: "paid" | "trial_full" | "trial_teleport_only" | "none"
//             | "expired" | "revoked" | "blocked" (reason:"machine_changed" optional)
"use strict";

const http = require("http");

const TIER = process.env.VANISH_FAKE_TIER || "paid";
const PORT = Number(process.env.VANISH_FAKE_PORT || 8787);
const HOST = "127.0.0.1";

const entitlement = {
  tier: TIER,
  trial_expires_at: TIER.startsWith("trial") ? new Date(Date.now() + 3600e3).toISOString() : null,
  email: TIER === "paid" ? "paid@localhost" : null,
  billing_portal_available: TIER === "paid",
  extension_available: false,
  ...(TIER === "revoked" && process.env.VANISH_FAKE_REASON
    ? { reason: process.env.VANISH_FAKE_REASON }
    : {}),
};

function json(res, status, body) {
  const s = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(s),
  });
  res.end(s);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const endpoint = url.pathname.replace(/\/$/, "").split("/").pop();
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    let parsed = {};
    try { parsed = body ? JSON.parse(body) : {}; } catch {}
    console.log(`[fake-backend] ${req.method} ${url.pathname} -> ${endpoint}`, body.slice(0, 200));

    switch (endpoint) {
      case "entitlement-get":
        return json(res, 200, { entitlement });
      case "trial-bootstrap":
      case "trial-start":
      case "trial-extend":
        return json(res, 200, { ok: true });
      case "checkout-status":
        return json(res, 200, { completed: false });
      case "pricing-get":
        return json(res, 200, { ok: true, prices: {} });
      case "track-event":
        return json(res, 202, { ok: true });
      case "dev-reset-machine":
        return json(res, 200, { ok: true });
      default:
        // Unknown/unneeded endpoints: the client wraps every backendPost in
        // try/catch and degrades to cached/tier=none behavior — 404 is safe.
        return json(res, 404, { ok: false, error: "not implemented by fake-backend" });
    }
  });
});

server.listen(PORT, HOST, () => {
  console.log(`[fake-backend] listening on http://${HOST}:${PORT} — serving tier="${TIER}"`);
});
