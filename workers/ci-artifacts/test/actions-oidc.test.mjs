import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import test from "node:test";
import { ACTIONS_OIDC_AUDIENCE, authenticateActionsRequest } from "../src/actions-oidc.ts";

const now = Date.parse("2026-09-21T09:00:00Z");
const seconds = Math.floor(now / 1000);
const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = publicKey.export({ format: "jwk" });
Object.assign(jwk, { kid: "fixture-key", use: "sig", alg: "RS256" });

function encode(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function token(overrides = {}, headerOverrides = {}) {
  const header = encode({ alg: "RS256", typ: "JWT", kid: "fixture-key", ...headerOverrides });
  const payload = encode({
    iss: "https://token.actions.githubusercontent.com",
    aud: ACTIONS_OIDC_AUDIENCE,
    repository: "manaflow-ai/cmux",
    repository_id: "1144115288",
    repository_owner_id: "171392238",
    repository_visibility: "public",
    workflow_ref: "manaflow-ai/cmux/.github/workflows/ci.yml@refs/pull/13364/merge",
    event_name: "pull_request",
    run_id: "35580000000",
    run_attempt: "1",
    iat: seconds - 30,
    nbf: seconds - 30,
    exp: seconds + 270,
    ...overrides,
  });
  const input = `${header}.${payload}`;
  const signature = sign("RSA-SHA256", Buffer.from(input), privateKey).toString("base64url");
  return `${input}.${signature}`;
}

async function keys(request) {
  assert.equal(new URL(request.url).href, "https://token.actions.githubusercontent.com/.well-known/jwks");
  return Response.json({ keys: [jwk] });
}

function request(value = token()) {
  return new Request("https://broker.example/v1/manaflow-ai/cmux/artifacts/1/" + "a".repeat(64) + ".zip", {
    headers: { Authorization: `Bearer ${value}` },
  });
}

test("accepts a signed identity only for cmux CI", async () => {
  const identity = await authenticateActionsRequest(request(), keys, now);
  assert.deepEqual(identity, { runId: "35580000000", runAttempt: "1", eventName: "pull_request" });
});

for (const [name, overrides] of [
  ["audience", { aud: "other" }],
  ["repository", { repository: "someone/cmux" }],
  ["repository id", { repository_id: "1" }],
  ["owner id", { repository_owner_id: "1" }],
  ["visibility", { repository_visibility: "private" }],
  ["workflow", { workflow_ref: "manaflow-ai/cmux/.github/workflows/nightly.yml@refs/heads/main" }],
  ["event", { event_name: "push" }],
  ["expiry", { exp: seconds - 31 }],
  ["future nbf", { nbf: seconds + 31 }],
  ["stale issue time", { iat: seconds - 601 }],
]) {
  test(`rejects wrong ${name}`, async () => {
    await assert.rejects(authenticateActionsRequest(request(token(overrides)), keys, now));
  });
}

test("rejects missing bearer identity, bad signature, and unavailable keys", async () => {
  await assert.rejects(authenticateActionsRequest(new Request("https://broker.example/"), keys, now));
  const signed = token();
  const corrupted = signed.slice(0, -1) + (signed.endsWith("a") ? "b" : "a");
  await assert.rejects(authenticateActionsRequest(request(corrupted), keys, now));
  await assert.rejects(authenticateActionsRequest(request(), async () => new Response("down", { status: 503 }), now));
});

test("accepts merge queue and manual CI events with the same workflow identity", async () => {
  for (const event_name of ["merge_group", "workflow_dispatch"]) {
    const identity = await authenticateActionsRequest(request(token({ event_name })), keys, now);
    assert.equal(identity.eventName, event_name);
  }
});
