import assert from "node:assert/strict";
import test from "node:test";
import { canaryAllowed, CANARY_PATH } from "../src/canary-route.ts";

const token = "a".repeat(64);
const request = (url, init = {}) => new Request(url, { ...init, headers: { "X-Cmux-Canary-Token": token } });
const expiry = "2026-09-20T20:00:00Z";
const now = Date.parse("2026-09-20T19:50:00Z");
const allowed = (request, enabled) => canaryAllowed(request, enabled, expiry, token, now);
const origin = "https://cmux-ci-artifacts-canary.example.workers.dev";
test("only enabled exact-artifact GET can reach the broker", () => {
  assert.equal(allowed(request(origin + CANARY_PATH), "true"), true);
  for (const enabled of [undefined, "", "false", "1"]) {
    assert.equal(allowed(request(origin + CANARY_PATH), enabled), false);
  }
  for (const path of [CANARY_PATH + "?extra=1", CANARY_PATH.replace("10610975375", "10610975376"),
    CANARY_PATH.replace("08f56e", "18f56e"), CANARY_PATH.replace("manaflow-ai", "other"), "/"]) {
    assert.equal(allowed(request(origin + path), "true"), false);
  }
  for (const method of ["POST", "PUT", "DELETE", "HEAD"]) {
    assert.equal(allowed(request(origin + CANARY_PATH, { method }), "true"), false);
  }
});

test("missing, expired and over-artifact-lifetime leases deny", () => {
  for (const expires of [undefined, "", "garbage", "2026-09-20T19:49:59Z", "2026-09-23T18:16:24Z"]) {
    assert.equal(canaryAllowed(request(origin + CANARY_PATH), "true", expires, token, now), false);
  }
});

test("missing/wrong per-run credentials deny before broker work", () => {
  assert.equal(canaryAllowed(new Request(origin + CANARY_PATH), "true", expiry, token, now), false);
  assert.equal(canaryAllowed(request(origin + CANARY_PATH), "true", expiry, undefined, now), false);
  assert.equal(canaryAllowed(request(origin + CANARY_PATH), "true", expiry, "b".repeat(64), now), false);
});
