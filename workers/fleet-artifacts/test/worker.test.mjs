import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import test from "node:test";
import worker from "../src/index.mjs";

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const publicHex = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
const digest = "a".repeat(64);
const payload = "verified artifact bytes";

function signedURL({ host = "artifacts.example.com", path = `/artifacts/${digest}`, expires = Math.floor(Date.now() / 1000) + 300 } = {}) {
  const url = new URL(`https://${host}${path}`);
  const message = `fleet-artifact-v1\n${url.host}\n${url.pathname}\n${expires}`;
  url.searchParams.set("expires", String(expires));
  url.searchParams.set("signature", sign(null, Buffer.from(message), privateKey).toString("hex"));
  return url;
}

function environment(overrides = {}) {
  const calls = [];
  return {
    calls,
    env: {
      ARTIFACT_PUBLIC_KEY: publicHex,
      ARTIFACTS: {
        async get(key) { calls.push(["get", key]); return { size: payload.length, body: new Blob([payload]).stream() }; },
        async head(key) { calls.push(["head", key]); return { size: payload.length }; },
      },
      ...overrides,
    },
  };
}

async function denied(url, overrides = {}, method = "GET") {
  const { env, calls } = environment(overrides);
  const response = await worker.fetch(new Request(url, { method }), env);
  assert.equal(response.status, 403);
  assert.equal(response.headers.get("Cache-Control"), "private, no-store");
  assert.deepEqual(calls, []);
}

test("signed GET streams the requested digest from the private binding", async () => {
  const { env, calls } = environment();
  const response = await worker.fetch(new Request(signedURL()), env);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), payload);
  assert.equal(response.headers.get("Content-Length"), String(payload.length));
  assert.equal(response.headers.get("Content-Type"), "application/zip");
  assert.equal(response.headers.get("Cache-Control"), "private, no-store");
  assert.deepEqual(calls, [["get", `artifacts/${digest}`]]);
});

test("signed HEAD returns metadata without fetching the body", async () => {
  const { env, calls } = environment();
  const response = await worker.fetch(new Request(signedURL(), { method: "HEAD" }), env);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "");
  assert.equal(response.headers.get("Content-Length"), String(payload.length));
  assert.deepEqual(calls, [["head", `artifacts/${digest}`]]);
});

test("unsigned GET and HEAD never read storage", async () => {
  for (const method of ["GET", "HEAD"]) await denied(`https://artifacts.example.com/artifacts/${digest}`, {}, method);
});

test("authentication applies to every repeated request", async () => {
  const { env, calls } = environment();
  assert.equal((await worker.fetch(new Request(signedURL()), env)).status, 200);
  assert.equal((await worker.fetch(new Request(`https://artifacts.example.com/artifacts/${digest}`), env)).status, 403);
  assert.equal(calls.length, 1);
});

test("no list, uppercase digests, nested keys or arbitrary objects", async () => {
  for (const path of ["/", "/artifacts/", "/artifacts", `/artifacts/${digest.toUpperCase()}`, "/artifacts/probe/controller", `/artifacts/${digest}/extra`, `/retained/${digest}`]) {
    await denied(signedURL({ path }));
  }
});

test("expiry is strictly future and at most fifteen minutes", async () => {
  const now = Math.floor(Date.now() / 1000);
  await denied(signedURL({ expires: now }));
  await denied(signedURL({ expires: now - 1 }));
  await denied(signedURL({ expires: now + 901 }));
  const { env } = environment();
  assert.equal((await worker.fetch(new Request(signedURL({ expires: now + 900 })), env)).status, 200);
});

test("signature binds host, pathname and exact expiry", async () => {
  const changeHost = signedURL(); changeHost.host = "other.example.com";
  const changePath = signedURL(); changePath.pathname = `/artifacts/${"b".repeat(64)}`;
  const changeExpiry = signedURL(); changeExpiry.searchParams.set("expires", String(Number(changeExpiry.searchParams.get("expires")) + 1));
  for (const url of [changeHost, changePath, changeExpiry]) await denied(url);
});

test("forged and noncanonical signatures are rejected", async () => {
  for (const signature of ["0".repeat(128), "a".repeat(127), "A".repeat(128), "gg".repeat(64)]) {
    const url = signedURL(); url.searchParams.set("signature", signature); await denied(url);
  }
});

test("noncanonical expiration values are rejected", async () => {
  for (const expires of ["", "001234", "1e9", "-1", "1790000000.1", "9".repeat(20)]) {
    const url = signedURL(); url.searchParams.set("expires", expires); await denied(url);
  }
});

test("missing public key, invalid key and a different key fail closed", async () => {
  for (const ARTIFACT_PUBLIC_KEY of [undefined, "", "A".repeat(64), "0".repeat(63), "0".repeat(64)]) {
    await denied(signedURL(), { ARTIFACT_PUBLIC_KEY });
  }
});

test("duplicate, missing and extra query parameters never read storage", async () => {
  for (const key of ["signature", "expires"]) {
    const duplicate = signedURL(); duplicate.searchParams.append(key, duplicate.searchParams.get(key)); await denied(duplicate);
    const missing = signedURL(); missing.searchParams.delete(key); await denied(missing);
  }
  const extra = signedURL(); extra.searchParams.set("list", "true"); await denied(extra);
});

test("plaintext and fragment URLs are rejected", async () => {
  const plaintext = signedURL(); plaintext.protocol = "http:"; await denied(plaintext);
  const fragment = signedURL(); fragment.hash = "extra"; await denied(fragment);
});

test("all mutation methods are rejected before storage", async () => {
  for (const method of ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"]) {
    const { env, calls } = environment();
    const response = await worker.fetch(new Request(signedURL(), { method }), env);
    assert.equal(response.status, 405);
    assert.equal(response.headers.get("Allow"), "GET, HEAD");
    assert.deepEqual(calls, []);
  }
});

test("authorized absent artifact returns 404", async () => {
  const { env } = environment({ ARTIFACTS: { async get() { return null; } } });
  assert.equal((await worker.fetch(new Request(signedURL()), env)).status, 404);
});

test("storage failure is bounded and never returns exception details", async () => {
  const { env } = environment({ ARTIFACTS: { async get() { throw Error("sensitive backend details"); } } });
  const response = await worker.fetch(new Request(signedURL()), env);
  assert.equal(response.status, 503);
  assert.equal(await response.text(), "Artifact unavailable");
});
