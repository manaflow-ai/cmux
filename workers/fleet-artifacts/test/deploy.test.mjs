import assert from "node:assert/strict";
import test from "node:test";
import { preflight, verifyUnsigned, workerName } from "../deploy.mjs";

function config(overrides = {}) {
  const calls = [];
  const data = {
    [`r2/buckets/${workerName}`]: { name: workerName },
    [`r2/buckets/${workerName}/domains/managed`]: { enabled: false },
    [`r2/buckets/${workerName}/domains/custom`]: { domains: [] },
    "workers/subdomain": { subdomain: "example-account" },
    ...overrides,
  };
  return {
    calls,
    options: {
      accountId: "a".repeat(32), token: "test-credential", publicKey: "b".repeat(64),
      async request(url, options) {
        calls.push({ url, method: options.method });
        const path = new URL(url).pathname.split("/accounts/")[1].split("/").slice(1).join("/");
        assert.equal(options.redirect, "error");
        assert.equal(options.headers.Authorization, "Bearer test-credential");
        return Response.json({ success: true, result: data[path] });
      },
    },
  };
}

test("preflight only reads the fixed existing bucket and account routing", async () => {
  const { options, calls } = config();
  assert.equal(await preflight(options), "https://cmux-fleet-artifacts.example-account.workers.dev");
  assert.equal(calls.length, 4);
  assert.ok(calls.every((call) => call.method === "GET"));
  assert.ok(calls.slice(0, 3).every((call) => new URL(call.url).pathname.includes("/r2/buckets/cmux-fleet-artifacts")));
});

test("invalid public key or credentials are rejected before API access", async () => {
  for (const invalid of [{ publicKey: "A".repeat(64) }, { publicKey: "" }, { accountId: "arbitrary-account" }, { token: "" }]) {
    const { options, calls } = config();
    await assert.rejects(preflight({ ...options, ...invalid }));
    assert.equal(calls.length, 0);
  }
});

test("wrong bucket, public access or malformed API metadata cannot deploy", async () => {
  for (const override of [
    { [`r2/buckets/${workerName}`]: { name: "other-bucket" } },
    { [`r2/buckets/${workerName}/domains/managed`]: { enabled: true } },
    { [`r2/buckets/${workerName}/domains/managed`]: {} },
    { [`r2/buckets/${workerName}/domains/custom`]: { domains: [{ enabled: true }] } },
    { [`r2/buckets/${workerName}/domains/custom`]: {} },
    { "workers/subdomain": { subdomain: "not/a/subdomain" } },
  ]) {
    const { options, calls } = config(override);
    await assert.rejects(preflight(options));
    assert.ok(calls.every((call) => call.method === "GET"));
  }
});

test("API failure never triggers bucket creation or another account", async () => {
  for (const status of [401, 403, 404, 500]) {
    const { options } = config();
    let requests = 0;
    await assert.rejects(preflight({ ...options, async request() { requests++; return new Response(null, { status }); } }));
    assert.equal(requests, 1);
  }
});

test("post-deploy verification checks an unsigned request with exact denial response", async () => {
  let requests = 0;
  await verifyUnsigned("https://cmux-fleet-artifacts.example-account.workers.dev", async (url) => {
    requests++;
    assert.equal(new URL(url).search, "");
    assert.equal(new URL(url).pathname, `/artifacts/${"0".repeat(64)}`);
    return new Response("Artifact unavailable", { status: 403, headers: { "Cache-Control": "private, no-store" } });
  });
  assert.equal(requests, 1);
});

test("verification rejects an exposed object or unrelated platform denial", async () => {
  for (const response of [new Response("artifact", { status: 200 }), new Response("Platform error", { status: 403 }), new Response("Artifact unavailable", { status: 403 })]) {
    await assert.rejects(verifyUnsigned("https://cmux-fleet-artifacts.example-account.workers.dev", async () => response));
  }
});

test("verification cannot send requests to arbitrary destinations", async () => {
  for (const origin of ["http://cmux-fleet-artifacts.example.workers.dev", "https://other.example.workers.dev", "https://cmux-fleet-artifacts.example.workers.dev/extra", "https://cmux-fleet-artifacts.example.workers.dev?token=1"]) {
    let requests = 0;
    await assert.rejects(verifyUnsigned(origin, async () => { requests++; }));
    assert.equal(requests, 0);
  }
});
