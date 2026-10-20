import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { setTimeout } from "node:timers/promises";
import test from "node:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";

const bytes = Buffer.from("opaque compressed GitHub artifact ZIP bytes");
const digest = createHash("sha256").update(bytes).digest("hex");
const path = `/v1/manaflow-ai/cmux/artifacts/123/${digest}.zip`;
const key = `github/manaflow-ai/cmux/123/${digest}.zip`;

// Faults live outside the production Worker. The wrapper delegates to the real
// R2 binding after a service-controlled gate, including the actual streaming put.
const coreWrapper = `
import { artifactHandler, ArtifactImport } from "./index.js";
export { ArtifactImport };
export default { fetch(request, env) { return artifactHandler(request, env); } };
`;

const boundWrapper = `
import { artifactHandler, ArtifactImport } from "./index.js";
export { ArtifactImport };
export default {
  fetch(request, env) {
    return artifactHandler(request, env, "999", "1");
  },
};
`;

const faultWrapper = `
import { artifactHandler, ArtifactImport as ProductionImport } from "./index.js";
export class ArtifactImport extends ProductionImport {
  constructor(ctx, env) {
    const bucket = {};
    for (const method of ["head", "get", "put"]) {
      bucket[method] = async (...args) => {
        const fault = await env.R2_FAULT.fetch("http://fault/" + method + "/start");
        if (!fault.ok) throw new Error("injected R2 failure");
        try { return await env.ARTIFACTS[method](...args); }
        finally { await env.R2_FAULT.fetch("http://fault/" + method + "/settled"); }
      };
    }
    super(ctx, { ...env, ARTIFACTS: bucket });
  }
}
export default { fetch(request, env) { return artifactHandler(request, env); } };
`;

function r2Gate(method, fail = false) {
  let release, entered;
  const pending = new Promise((resolve) => { release = resolve; });
  const started = new Promise((resolve) => { entered = resolve; });
  const state = { calls: 0, active: 0, settled: 0, maxActive: 0 };
  return {
    state, release, started,
    async fetch(request) {
      const [actual, phase] = new URL(request.url).pathname.slice(1).split("/");
      if (actual === method) {
        if (phase === "start") {
          state.calls++;
          state.active++;
          state.maxActive = Math.max(state.maxActive, state.active);
          entered();
          await pending;
        } else {
          state.active--;
          state.settled++;
        }
      }
      return new Response("ok", { status: fail && actual === method && phase === "start" ? 503 : 200 });
    },
  };
}

async function fixture(t, options = {}) {
  const state = { downloads: 0, api: 0, private: false, failed: false, corrupt: false, ...options };
  const bundled = new URL("../.test-dist/index.js", import.meta.url);
  const mf = new Miniflare(convertV4MiniflareOptions({
    modules: [
      {
        type: "ESModule",
        path: new URL(options.r2Gate ? "../.test-dist/fault-wrapper.js" : options.boundRun ? "../.test-dist/bound-wrapper.js" : "../.test-dist/core-wrapper.js", import.meta.url).pathname,
        contents: options.r2Gate ? faultWrapper : options.boundRun ? boundWrapper : coreWrapper,
      },
      { type: "ESModule", path: bundled.pathname, contents: readFileSync(bundled, "utf8") },
    ],
    ...(options.r2Gate ? { serviceBindings: { R2_FAULT: options.r2Gate.fetch } } : {}),
    compatibilityDate: "2026-09-20", compatibilityFlags: ["nodejs_compat"],
    bindings: { GITHUB_ARTIFACT_TOKEN: "server-only-token", IMPORT_TIMEOUT_MS: String(options.timeoutMs || 150_000) },
    r2Buckets: ["ARTIFACTS"],
    durableObjects: { ARTIFACT_IMPORTS: { className: "ArtifactImport", useSQLite: true } },
    outboundService: async (request) => {
      const url = new URL(request.url);
      if (url.hostname === "objects.blob.core.windows.net") {
        assert.equal(request.headers.get("Authorization"), null, "token must not follow signed redirect");
        state.downloads++;
        await setTimeout(state.delayMs || 25); // Keep the first transfer open during concurrent arrivals.
        const body = state.corrupt ? Buffer.alloc(bytes.length, 0) : bytes;
        return new Response(body, { headers: { "Content-Length": String(bytes.length) } });
      }
      assert.equal(url.hostname, "api.github.com");
      assert.equal(request.headers.get("Authorization"), "Bearer server-only-token");
      state.api++;
      const root = "/repos/manaflow-ai/cmux";
      if (url.pathname === root) return Response.json({ full_name: "manaflow-ai/cmux", private: state.private });
      if (url.pathname === `${root}/actions/artifacts/123`) {
        if (state.apiFailure) return new Response("provider unavailable", { status: 503 });
        return Response.json({
          id: 123, name: `app-host-products-v1-${"a".repeat(64)}-1`, expired: Boolean(state.expired),
          digest: `sha256:${state.wrongDigest ? "f".repeat(64) : digest}`, size_in_bytes: bytes.length, workflow_run: { id: 456 },
        });
      }
      if (url.pathname === `${root}/actions/runs/456`) return Response.json({
        path: state.wrongWorkflow ? ".github/workflows/other.yml" : ".github/workflows/ci.yml",
        event: "pull_request", head_repository: { full_name: state.wrongProducer ? "someone/cmux" : "manaflow-ai/cmux" },
        run_attempt: 1, status: "in_progress", conclusion: null,
      });
      if (url.pathname === `${root}/actions/runs/456/attempts/1/jobs`) return Response.json({ jobs: [{
        name: "macOS compile admission", status: "completed", conclusion: state.failed ? "failure" : "success",
      }] });
      if (url.pathname === `${root}/actions/artifacts/123/zip`) return new Response(null, {
        status: 302, headers: { Location: state.badRedirect ? "https://attacker.example/blob" : "https://objects.blob.core.windows.net/artifact.zip?signature=private" },
      });
      throw new Error(`unexpected path ${url.pathname}`);
    },
  }));
  t.after(() => mf.dispose());
  return { mf, state };
}

test("all seven immediate consumers share one import while the overall CI run is active", async (t) => {
  const { mf, state } = await fixture(t);
  const responses = await Promise.all(Array.from({ length: 7 }, () => mf.dispatchFetch(`https://broker.example${path}`)));
  for (const response of responses) {
    assert.equal(response.status, 200);
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes);
  }
  assert.equal(state.downloads, 1);
  const hit = await mf.dispatchFetch(`https://broker.example${path}`);
  assert.equal(hit.headers.get("X-Cmux-Artifact-Cache"), "hit");
  await hit.arrayBuffer();
  assert.equal(state.downloads, 1);
});

test("R2 rejects corrupt bytes and a later retry can fill the same immutable key", async (t) => {
  const { mf, state } = await fixture(t, { corrupt: true });
  assert.equal((await mf.dispatchFetch(`https://broker.example${path}`)).status, 502);
  const bucket = await mf.getR2Bucket("ARTIFACTS");
  assert.equal(await bucket.head(key), null);
  state.corrupt = false;
  const response = await mf.dispatchFetch(`https://broker.example${path}`);
  assert.equal(response.status, 200);
  await response.arrayBuffer();
  assert.equal(state.downloads, 2);
});

for (const option of ["failed", "wrongWorkflow", "wrongProducer", "expired", "wrongDigest", "apiFailure", "badRedirect", "private"]) {
  test(`rejects ${option} provenance without importing bytes`, async (t) => {
    const { mf, state } = await fixture(t, { [option]: true });
    assert.equal((await mf.dispatchFetch(`https://broker.example${path}`)).status, 502);
    assert.equal(state.downloads, 0);
    assert.equal(await (await mf.getR2Bucket("ARTIFACTS")).head(key), null);
  });
}


test("R2 write failure returns a miss and leaves no cached object", async (t) => {
  const gate = r2Gate("put", true);
  gate.release();
  const { mf, state } = await fixture(t, { r2Gate: gate });
  const response = await mf.dispatchFetch(`https://broker.example${path}`);
  assert.equal(response.status, 502);
  assert.equal(state.downloads, 1);
  assert.equal(await (await mf.getR2Bucket("ARTIFACTS")).head(key), null);
});

test("production caller run identity must match the artifact producer", async (t) => {
  const { mf, state } = await fixture(t, { boundRun: true });
  const response = await mf.dispatchFetch(`https://broker.example${path}`);
  assert.equal(response.status, 502);
  assert.equal(state.downloads, 0);
  assert.equal(await (await mf.getR2Bucket("ARTIFACTS")).head(key), null);
});

test("other repositories and client writes never reach authenticated GitHub", async (t) => {
  const { mf, state } = await fixture(t);
  assert.equal((await mf.dispatchFetch(`https://broker.example${path.replace("manaflow-ai/cmux", "someone/private")}`)).status, 404);
  assert.equal((await mf.dispatchFetch(`https://broker.example${path}`, { method: "PUT", body: "poison" })).status, 404);
  assert.equal(state.api, 0);
});

test("cached bytes are withheld when the repository is no longer public", async (t) => {
  const { mf, state } = await fixture(t);
  await (await mf.dispatchFetch(`https://broker.example${path}`)).arrayBuffer();
  state.private = true;
  assert.equal((await mf.dispatchFetch(`https://broker.example${path}`)).status, 502);
  assert.equal(state.downloads, 1);
});


test("concurrent cold misses time out together instead of holding consumers indefinitely", async (t) => {
  const { mf, state } = await fixture(t, { timeoutMs: 50, delayMs: 250 });
  const started = Date.now();
  const responses = await Promise.all(Array.from({ length: 6 }, () => mf.dispatchFetch(`https://broker.example${path}`)));
  assert.ok(responses.every((response) => response.status === 502));
  assert.ok(Date.now() - started < 2000, "broker deadline must release consumers for GitHub fallback");
  assert.equal(state.downloads, 1);
  assert.equal(await (await mf.getR2Bucket("ARTIFACTS")).head(key), null);
});


for (const method of ["head", "put", "get"]) {
  test(`stalled R2 ${method} bounds consumers and permits retry only after late I/O settles`, { timeout: 20_000 }, async (t) => {
    const gate = r2Gate(method);
    // Release before fixture disposal, even if an assertion fails.
    t.after(gate.release);
    const { mf, state } = await fixture(t, { timeoutMs: 250, delayMs: 0, r2Gate: gate });
    await mf.ready; // Runtime startup is outside the HTTP deadline.
    const started = Date.now();
    const request = () => mf.dispatchFetch(`https://broker.example${path}`);
    const first = request();
    await gate.started;
    const budget = method === "get" ? 12_000 : 2_000;
    let deadline;
    const response = await Promise.race([
      first,
      new Promise((_, reject) => {
        deadline = globalThis.setTimeout(() => reject(new Error("stalled binding held HTTP consumer")), budget);
      }),
    ]).finally(() => clearTimeout(deadline));
    assert.equal(response.status, 502);
    // head/put waiters use the import deadline; get has its own 10s R2 deadline.
    assert.ok(Date.now() - started < (method === "get" ? 12_000 : 2_000), "stalled binding must release HTTP consumers");
    assert.equal(gate.state.active, 1, "caller deadline must not pretend binding I/O settled");
    assert.equal(gate.state.settled, 0);

    if (method !== "get") {
      const followers = await Promise.all(Array.from({ length: 3 }, request));
      assert.ok(followers.every((item) => item.status === 502));
      assert.equal(gate.state.calls, 1, "timed-out consumers must not start overlapping imports");
      assert.equal(gate.state.maxActive, 1);
      assert.equal(state.downloads, method === "put" ? 1 : 0);
      assert.equal(await (await mf.getR2Bucket("ARTIFACTS")).head(key), null);
    } else {
      assert.equal(state.downloads, 1, "get stalls must not restart the completed transfer");
    }

    gate.release();
    // Settlement crosses the service boundary before import cleanup's final
    // microtask. Retry until that cleanup finishes, with a separate test bound.
    const retryDeadline = Date.now() + 2_000;
    let retry;
    do {
      retry = await request();
      if (retry.status === 200) break;
      await setTimeout(10);
    } while (Date.now() < retryDeadline);
    assert.equal(retry.status, 200, "late binding completion must eventually allow a fresh request");
    assert.deepEqual(Buffer.from(await retry.arrayBuffer()), bytes);
    assert.ok(gate.state.settled >= 1);
    assert.equal(gate.state.active, 0);
    if (method !== "get") assert.equal(gate.state.maxActive, 1, "retry must not overlap the orphaned transfer");
    assert.equal(state.downloads, method === "put" ? 2 : 1);
  });
}
