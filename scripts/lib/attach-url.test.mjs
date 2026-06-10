// Unit tests for the attach-url encoder.
//   node --test scripts/lib/attach-url.test.mjs

import assert from "node:assert/strict";
import test from "node:test";

import { buildAttachURL, filterRoutes } from "./attach-url.mjs";

function samplePayload() {
  return {
    ticket: {
      version: 1,
      workspaceID: "",
      routes: [
        { id: "ts", kind: "tailscale", endpoint: { type: "host_port", host: "100.1.2.3", port: 8080 } },
        { id: "lo", kind: "loopback", endpoint: { type: "host_port", host: "127.0.0.1", port: 8080 } },
      ],
      authToken: "secret-token",
    },
    expires_at: "2026-06-07T00:00:00Z",
  };
}

function decodePayload(url) {
  const params = new URL(url).searchParams;
  const b64 = params.get("payload");
  return JSON.parse(Buffer.from(b64, "base64url").toString("utf8"));
}

test("builds a cmux-ios://attach URL with the version and base64url ticket", () => {
  const { attachURL } = buildAttachURL(samplePayload());
  assert.match(attachURL, /^cmux-ios:\/\/attach\?v=1&payload=/);
  const decoded = decodePayload(attachURL);
  assert.equal(decoded.version, 1);
  assert.equal(decoded.authToken, "secret-token");
  assert.equal(decoded.routes.length, 2);
});

test("round-trips the encoded ticket back to the original object", () => {
  const payload = samplePayload();
  const { attachURL } = buildAttachURL(payload);
  const decoded = decodePayload(attachURL);
  assert.deepEqual(decoded, payload.ticket);
});

test("filters routes by kind and narrows the encoded ticket", () => {
  const { attachURL, routes } = buildAttachURL(samplePayload(), { routeKind: "tailscale" });
  assert.equal(routes.length, 1);
  assert.equal(routes[0].id, "ts");
  const decoded = decodePayload(attachURL);
  assert.equal(decoded.routes.length, 1);
  assert.equal(decoded.routes[0].kind, "tailscale");
});

test("filters routes by id", () => {
  const { routes } = buildAttachURL(samplePayload(), { routeID: "lo" });
  assert.equal(routes.length, 1);
  assert.equal(routes[0].id, "lo");
});

test("throws when no route matches the filter", () => {
  assert.throws(() => buildAttachURL(samplePayload(), { routeKind: "nope" }), /No matching route/);
});

test("throws when the payload has no ticket routes", () => {
  assert.throws(() => buildAttachURL({ ticket: {} }), /ticket with routes/);
  assert.throws(() => buildAttachURL({}), /ticket with routes/);
});

test("defaults version to 1 when the ticket omits it", () => {
  const payload = samplePayload();
  delete payload.ticket.version;
  const { attachURL } = buildAttachURL(payload);
  assert.match(attachURL, /\?v=1&/);
});

test("filterRoutes returns all routes when no filter is given", () => {
  const routes = samplePayload().ticket.routes;
  assert.equal(filterRoutes(routes).length, 2);
});

test("does not mutate the caller's payload", () => {
  const payload = samplePayload();
  buildAttachURL(payload, { routeKind: "tailscale" });
  assert.equal(payload.ticket.routes.length, 2);
});
