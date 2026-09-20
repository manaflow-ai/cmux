import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { setTimeout } from "node:timers/promises";
import test from "node:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";

const bytes = Buffer.from("opaque compressed GitHub artifact ZIP bytes");
const digest = createHash("sha256").update(bytes).digest("hex");
const path = `/v1/manaflow-ai/cmux/artifacts/123/${digest}.zip`;
const key = `github/manaflow-ai/cmux/123/${digest}.zip`;

async function fixture(t, options = {}) {
  const state = { downloads: 0, api: 0, private: false, failed: false, corrupt: false, ...options };
  const mf = new Miniflare(convertV4MiniflareOptions({
    modules: true,
    scriptPath: new URL("../.test-dist/index.js", import.meta.url).pathname,
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
      if (url.pathname === `${root}/actions/artifacts/123`) return Response.json({
        id: 123, name: `app-host-products-v1-${"a".repeat(64)}-1`, expired: false,
        digest: `sha256:${digest}`, size_in_bytes: bytes.length, workflow_run: { id: 456 },
      });
      if (url.pathname === `${root}/actions/runs/456`) return Response.json({
        path: state.wrongWorkflow ? ".github/workflows/other.yml" : ".github/workflows/ci.yml",
        event: "pull_request", head_repository: { full_name: "manaflow-ai/cmux" },
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

test("six immediate consumers share one import while the overall CI run is active", async (t) => {
  const { mf, state } = await fixture(t);
  const responses = await Promise.all(Array.from({ length: 6 }, () => mf.dispatchFetch(`https://broker.example${path}`)));
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

for (const option of ["failed", "wrongWorkflow", "badRedirect", "private"]) {
  test(`rejects ${option} provenance without importing bytes`, async (t) => {
    const { mf, state } = await fixture(t, { [option]: true });
    assert.equal((await mf.dispatchFetch(`https://broker.example${path}`)).status, 502);
    assert.equal(state.downloads, 0);
    assert.equal(await (await mf.getR2Bucket("ARTIFACTS")).head(key), null);
  });
}

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
