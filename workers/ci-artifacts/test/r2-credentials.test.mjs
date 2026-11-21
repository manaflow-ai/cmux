import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import test from "node:test";
import {
  CREDENTIAL_TTL_SECONDS,
  R2_CREDENTIALS_AUDIENCE,
  handleCredentialRequest,
} from "../.test-dist-r2-credentials/r2-credentials.js";

const now = Date.parse("2026-10-30T09:00:00Z");
const seconds = Math.floor(now / 1000);
const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = publicKey.export({ format: "jwk" });
Object.assign(jwk, { kid: "fixture-key", use: "sig", alg: "RS256" });

const env = {
  CLOUDFLARE_API_TOKEN: "parent-api-token-value",
  R2_ACCOUNT_ID: "0123456789abcdef0123456789abcdef",
  R2_PARENT_ACCESS_KEY_ID: "parent-access-key-id",
};
const workflowRef = "manaflow-ai/cmuxterm-hq/.github/workflows/nightly-next-linux.yml@refs/heads/main";
const prefix = `nightly-next/next/dsyms/${"a".repeat(40)}/4100000000001-41000000000-1/`;

function encode(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function token(overrides = {}) {
  const header = encode({ alg: "RS256", typ: "JWT", kid: "fixture-key" });
  const payload = encode({
    iss: "https://token.actions.githubusercontent.com",
    aud: R2_CREDENTIALS_AUDIENCE,
    sub: "repo:manaflow-ai/cmuxterm-hq:environment:nightly-next-linux",
    repository: "manaflow-ai/cmuxterm-hq",
    repository_id: "1162953520",
    repository_owner_id: "171392238",
    repository_visibility: "private",
    workflow_ref: workflowRef,
    job_workflow_ref: workflowRef,
    ref: "refs/heads/main",
    environment: "nightly-next-linux",
    event_name: "schedule",
    run_id: "41000000000",
    run_attempt: "1",
    iat: seconds - 30,
    nbf: seconds - 30,
    exp: seconds + 270,
    ...overrides,
  });
  const input = `${header}.${payload}`;
  return `${input}.${sign("RSA-SHA256", Buffer.from(input), privateKey).toString("base64url")}`;
}

function fakeCloudflare(response) {
  const calls = [];
  const fetcher = async (input, init = {}) => {
    const url = typeof input === "string" ? input : input.url;
    if (url === "https://token.actions.githubusercontent.com/.well-known/jwks") return Response.json({ keys: [jwk] });
    calls.push({ url, init, body: JSON.parse(init.body) });
    return typeof response === "function" ? response() : Response.json(response ?? {
      success: true,
      errors: [],
      messages: [],
      result: { accessKeyId: "temp-access-key", secretAccessKey: "temp-secret", sessionToken: "temp-session" },
    });
  };
  return { fetcher, calls };
}

function request(body = { grant: "nightly-next-dsyms", prefix }, value = token(), init = {}) {
  return new Request("https://r2-credentials.example/v1/r2-credentials", {
    method: "POST",
    headers: { Authorization: `Bearer ${value}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    ...init,
  });
}

test("issues 15-minute credentials scoped to one run's prefix for the HQ nightly build job", async () => {
  const { fetcher, calls } = fakeCloudflare();
  const response = await handleCredentialRequest(request(), env, fetcher, now);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const body = await response.json();
  assert.equal(CREDENTIAL_TTL_SECONDS, 900);
  assert.deepEqual(body, {
    accessKeyId: "temp-access-key",
    secretAccessKey: "temp-secret",
    sessionToken: "temp-session",
    expiresAt: new Date((seconds + 900) * 1000).toISOString(),
    ttlSeconds: 900,
    grant: "nightly-next-dsyms",
    bucket: "cmux-nightly-next",
    prefix,
    permission: "object-read-write",
    identity: {
      repository: "manaflow-ai/cmuxterm-hq",
      workflowRef,
      ref: "refs/heads/main",
      environment: "nightly-next-linux",
      eventName: "schedule",
      runId: "41000000000",
      runAttempt: "1",
    },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `https://api.cloudflare.com/client/v4/accounts/${env.R2_ACCOUNT_ID}/r2/temp-access-credentials`);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.redirect, "error");
  assert.equal(calls[0].init.headers.Authorization, "Bearer parent-api-token-value");
  assert.deepEqual(calls[0].body, {
    bucket: "cmux-nightly-next",
    parentAccessKeyId: "parent-access-key-id",
    permission: "object-read-write",
    ttlSeconds: 900,
    prefixes: [prefix],
  });
  assert.ok(!JSON.stringify(body).includes("parent-api-token-value"));
});

test("an ordinary job's token without job_workflow_ref gets credentials", async () => {
  // GitHub's docs define job_workflow_ref only for jobs that use a reusable workflow.
  const { fetcher, calls } = fakeCloudflare();
  const response = await handleCredentialRequest(request(undefined, token({ job_workflow_ref: undefined })), env, fetcher, now);
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  assert.equal((await response.json()).identity.workflowRef, workflowRef);
});

test("a manual dispatch on main is allowed", async () => {
  const { fetcher } = fakeCloudflare();
  const response = await handleCredentialRequest(request(undefined, token({ event_name: "workflow_dispatch" })), env, fetcher, now);
  assert.equal(response.status, 200);
});

for (const [name, overrides, status] of [
  ["audience", { aud: "cmux-ci-artifacts" }, 401],
  ["issuer", { iss: "https://example.com" }, 401],
  ["expired token", { exp: seconds - 31 }, 401],
  ["future nbf", { nbf: seconds + 31 }, 401],
  ["stale issue time", { iat: seconds - 601 }, 401],
  ["repository", { repository: "manaflow-ai/cmux" }, 403],
  ["repository id (renamed or recreated repo)", { repository_id: "1" }, 403],
  ["owner id", { repository_owner_id: "1" }, 403],
  ["workflow file", { workflow_ref: "manaflow-ai/cmuxterm-hq/.github/workflows/other.yml@refs/heads/main" }, 403],
  ["workflow file with no job_workflow_ref", { workflow_ref: "manaflow-ai/cmuxterm-hq/.github/workflows/other.yml@refs/heads/main", job_workflow_ref: undefined }, 403],
  ["workflow ref on another branch", { workflow_ref: workflowRef.replace("main", "feature"), job_workflow_ref: undefined }, 403],
  ["missing workflow_ref", { workflow_ref: undefined }, 403],
  ["reusable workflow", { job_workflow_ref: "manaflow-ai/cmuxterm-hq/.github/workflows/reusable.yml@refs/heads/main" }, 403],
  ["ref", { ref: "refs/heads/feature", workflow_ref: workflowRef.replace("main", "feature"), job_workflow_ref: workflowRef.replace("main", "feature") }, 403],
  ["ref claim alone", { ref: "refs/pull/1/merge" }, 403],
  ["environment", { environment: "other" }, 403],
  ["missing environment", { environment: undefined }, 403],
  ["event", { event_name: "pull_request" }, 403],
  ["push event", { event_name: "push" }, 403],
  ["run id", { run_id: "not-a-run" }, 403],
]) {
  test(`rejects wrong ${name} without minting`, async () => {
    const { fetcher, calls } = fakeCloudflare();
    const response = await handleCredentialRequest(request(undefined, token(overrides)), env, fetcher, now);
    assert.equal(response.status, status);
    assert.equal(calls.length, 0);
  });
}

test("rejects a bad signature, a missing bearer token and unavailable keys", async () => {
  const { fetcher, calls } = fakeCloudflare();
  const [h, p, s] = token().split(".");
  const corrupted = `${h}.${p}.${(s.startsWith("A") ? "B" : "A") + s.slice(1)}`;
  assert.equal((await handleCredentialRequest(request(undefined, corrupted), env, fetcher, now)).status, 401);
  const anonymous = new Request("https://r2-credentials.example/v1/r2-credentials", { method: "POST", body: "{}" });
  assert.equal((await handleCredentialRequest(anonymous, env, fetcher, now)).status, 401);
  const down = async () => new Response("down", { status: 503 });
  assert.equal((await handleCredentialRequest(request(), env, down, now)).status, 401);
  assert.equal(calls.length, 0);
});

for (const [name, body] of [
  ["prefix outside the grant", { grant: "nightly-next-dsyms", prefix: "nightly-next/next/appcast/" }],
  ["the feed itself", { grant: "nightly-next-dsyms", prefix: "nightly-next/next/" }],
  ["traversal", { grant: "nightly-next-dsyms", prefix: "nightly-next/next/dsyms/../appcast-1-41000000000-1/" }],
  ["empty segment", { grant: "nightly-next-dsyms", prefix: "nightly-next/next/dsyms//x-41000000000-1/" }],
  ["another run's folder", { grant: "nightly-next-dsyms", prefix: "nightly-next/next/dsyms/abc/1-41000000001-1/" }],
  ["another attempt's folder", { grant: "nightly-next-dsyms", prefix: "nightly-next/next/dsyms/abc/1-41000000000-2/" }],
  ["the whole grant root", { grant: "nightly-next-dsyms" }],
  ["an object key instead of a prefix", { grant: "nightly-next-dsyms", prefix: prefix + "cmux.dSYM.tar.gz" }],
  ["a non-string prefix", { grant: "nightly-next-dsyms", prefix: ["nightly-next/next/dsyms/"] }],
]) {
  test(`rejects ${name}`, async () => {
    const { fetcher, calls } = fakeCloudflare();
    const response = await handleCredentialRequest(request(body), env, fetcher, now);
    assert.equal(response.status, 400);
    assert.equal(calls.length, 0);
  });
}

test("rejects unknown grants, inherited names and malformed bodies", async () => {
  const { fetcher, calls } = fakeCloudflare();
  assert.equal((await handleCredentialRequest(request({ grant: "nightly-next-feed", prefix }), env, fetcher, now)).status, 403);
  assert.equal((await handleCredentialRequest(request({ grant: "__proto__", prefix }), env, fetcher, now)).status, 403);
  assert.equal((await handleCredentialRequest(request({ grant: "toString", prefix }), env, fetcher, now)).status, 403);
  assert.equal((await handleCredentialRequest(request({ prefix }), env, fetcher, now)).status, 400);
  const notJson = new Request("https://r2-credentials.example/v1/r2-credentials", {
    method: "POST",
    headers: { Authorization: `Bearer ${token()}` },
    body: "grant=nightly-next-dsyms",
  });
  assert.equal((await handleCredentialRequest(notJson, env, fetcher, now)).status, 400);
  const huge = request({ grant: "nightly-next-dsyms", prefix, pad: "x".repeat(5000) });
  assert.equal((await handleCredentialRequest(huge, env, fetcher, now)).status, 400);
  assert.equal(calls.length, 0);
});

test("only POST on the one path, and an unconfigured Worker sends callers to the static secrets", async () => {
  const { fetcher, calls } = fakeCloudflare();
  const get = new Request("https://r2-credentials.example/v1/r2-credentials", { headers: { Authorization: `Bearer ${token()}` } });
  assert.equal((await handleCredentialRequest(get, env, fetcher, now)).status, 405);
  const other = new Request("https://r2-credentials.example/v1/other", { method: "POST" });
  assert.equal((await handleCredentialRequest(other, env, fetcher, now)).status, 404);
  const query = new Request("https://r2-credentials.example/v1/r2-credentials?x=1", { method: "POST" });
  assert.equal((await handleCredentialRequest(query, env, fetcher, now)).status, 404);
  for (const missing of ["CLOUDFLARE_API_TOKEN", "R2_ACCOUNT_ID", "R2_PARENT_ACCESS_KEY_ID"]) {
    const partial = { ...env, [missing]: "" };
    assert.equal((await handleCredentialRequest(request(), partial, fetcher, now)).status, 503);
  }
  assert.equal((await handleCredentialRequest(request(), { ...env, R2_ACCOUNT_ID: "not-an-account" }, fetcher, now)).status, 503);
  assert.equal(calls.length, 0);
});

for (const [name, response] of [
  ["an API error", () => new Response(JSON.stringify({ success: false, errors: [{ code: 10000 }] }), { status: 403 })],
  ["success false", { success: false, result: { accessKeyId: "a", secretAccessKey: "b", sessionToken: "c" } }],
  ["a missing session token", { success: true, result: { accessKeyId: "a", secretAccessKey: "b" } }],
  ["a missing result", { success: true }],
  ["a network failure", () => { throw new TypeError("fetch failed"); }],
]) {
  test(`returns 502 on ${name}, never the parent token`, async () => {
    const { fetcher, calls } = fakeCloudflare(response);
    const reply = await handleCredentialRequest(request(), env, fetcher, now);
    assert.equal(reply.status, 502);
    assert.equal(calls.length, 1);
    const text = await reply.text();
    assert.ok(!text.includes("parent-api-token-value"));
    assert.ok(!text.includes("parent-access-key-id"));
  });
}
