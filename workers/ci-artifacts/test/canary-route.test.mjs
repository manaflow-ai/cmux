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

// The wrapper's broker callback is its ordinary dependency, not a runtime test mode.
test("authenticated readiness never invokes broker; artifact still streams once", async () => {
  const { handleCanaryRequest, READINESS_PATH } = await import("../src/canary-route.ts");
  const configuration = { CANARY_ENABLED: "true", CANARY_EXPIRES_AT: expiry, CANARY_ACCESS_TOKEN: token };
  let imports = 0;
  const broker = async () => { imports++; return new Response("product", { headers: { "X-Cmux-Artifact-Cache": "fill" } }); };
  const ready = await handleCanaryRequest(request(origin + READINESS_PATH), configuration, broker, now);
  assert.equal(ready.status, 204);
  assert.equal(ready.headers.get("X-Cmux-Canary-Stage"), "ready-v1");
  assert.equal(imports, 0);
  const artifact = await handleCanaryRequest(request(origin + CANARY_PATH), configuration, broker, now);
  assert.equal(await artifact.text(), "product");
  assert.equal(artifact.headers.get("X-Cmux-Artifact-Cache"), "fill");
  assert.equal(artifact.headers.get("X-Cmux-Canary-Stage"), "artifact-v1");
  assert.equal(imports, 1);
});

test("all rejected readiness requests are marked and cannot call broker", async () => {
  const { handleCanaryRequest, READINESS_PATH } = await import("../src/canary-route.ts");
  const configuration = { CANARY_ENABLED: "true", CANARY_EXPIRES_AT: expiry, CANARY_ACCESS_TOKEN: token };
  let imports = 0;
  const broker = async () => { imports++; return new Response("unexpected"); };
  const cases = [
    [new Request(origin + READINESS_PATH), configuration],
    [request(origin + READINESS_PATH), { ...configuration, CANARY_ACCESS_TOKEN: "b".repeat(64) }],
    [request(origin + READINESS_PATH), { ...configuration, CANARY_ENABLED: "false" }],
    [request(origin + READINESS_PATH), { ...configuration, CANARY_EXPIRES_AT: "2026-09-20T19:00:00Z" }],
    [request(origin + READINESS_PATH, { method: "POST" }), configuration],
    [request(origin + READINESS_PATH + "?x=1"), configuration],
    [request(origin + "/unknown"), configuration],
  ];
  for (const [req, env] of cases) {
    const denied = await handleCanaryRequest(req, env, broker, now);
    assert.equal(denied.status, 404);
    assert.equal(denied.headers.get("X-Cmux-Canary-Stage"), "gate-rejected");
    assert.equal((await denied.text()).includes(token), false);
  }
  assert.equal(imports, 0);
});

test("broker errors retain status and get a non-secret artifact-stage marker", async () => {
  const { handleCanaryRequest } = await import("../src/canary-route.ts");
  const configuration = { CANARY_ENABLED: "true", CANARY_EXPIRES_AT: expiry, CANARY_ACCESS_TOKEN: token };
  const result = await handleCanaryRequest(request(origin + CANARY_PATH), configuration,
    async () => new Response("use fallback", { status: 502 }), now);
  assert.equal(result.status, 502);
  assert.equal(result.headers.get("X-Cmux-Canary-Stage"), "artifact-v1");
  assert.equal(await result.text(), "use fallback");
});
