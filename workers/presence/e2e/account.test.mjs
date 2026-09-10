import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";
import { Miniflare, Log, LogLevel } from "miniflare";

const directory = await mkdtemp(join(tmpdir(), "cmux-account-e2e-"));
const { outputFiles } = await build({
  entryPoints: [new URL("./account.worker.ts", import.meta.url).pathname],
  bundle: true, write: false, format: "esm", target: "es2022", external: ["cloudflare:workers"],
});
let runtime;
let outboundCalls = 0;
const start = async (stage = "base") => {
  runtime = new Miniflare({
    log: new Log(LogLevel.NONE), bindings: { MIGRATION_STAGE: stage },
    name: "account-storage-sandbox", modules: true, script: outputFiles[0].text,
    compatibilityDate: "2026-05-01", host: "127.0.0.1", port: 0,
    durableObjects: {
      ACCOUNT: { className: "SandboxAccount", useSQLite: true },
      SCHEMA: { className: "SandboxSchema", useSQLite: true },
      DRIZZLE: { className: "SandboxDrizzle", useSQLite: true },
    },
    durableObjectsPersist: directory,
    outboundService: () => { outboundCalls++; throw new Error("External network is blocked in this sandbox"); },
  });
  await runtime.ready;
};
const request = async (path, body) => {
  const response = await runtime.dispatchFetch(`http://sandbox${path}`, body === undefined ? {} : {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
  });
  const text = await response.text();
  assert.equal(response.status, 200, text);
  return JSON.parse(text);
};
try {
  await start();
  assert.deepEqual(await request("/drizzle/probe"), { rows: [] }, "Drizzle transaction must roll back atomically in workerd");
  const first = await request("/inspect");
  assert.deepEqual(first.schema, [{ version: 1, name: "account_state_tables" }]);
  assert.deepEqual(first.rows, []);
  assert.equal(first.alarm, null, "Empty SQL state must not start a permanent daily alarm");
  const expiry = Date.now() + 120_000;
  await request("/seed", { id: "keep", expiresAt: expiry });
  await request("/set-alarm", { at: expiry });
  await runtime.dispose();
  await start();
  const restarted = await request("/inspect");
  assert.equal(restarted.alarm, expiry, "Reactivation must preserve an existing earlier alarm");
  assert.deepEqual(restarted.rows, [{ challenge_id: "keep", expires_at: expiry }]);
  assert.deepEqual((await request("/inspect?account=b")).rows, [], "Accounts must have separate SQLite databases");
  await request("/seed", { id: "expired", expiresAt: Date.now() - 1 });
  await request("/alarm");
  const cleaned = await request("/inspect");
  assert.deepEqual(cleaned.rows, [{ challenge_id: "keep", expires_at: expiry }]);
  assert.equal(cleaned.alarm, expiry, "Idle object must rearm cleanup for retained records");
  await request("/seed?account=alarm", { id: "expire-by-alarm", expiresAt: Date.now() - 1 });
  await request("/set-alarm?account=alarm", { at: Date.now() + 50 });
  const deadline = Date.now() + 10_000;
  let delivered;
  do {
    delivered = await request("/inspect?account=alarm");
    if (delivered.alarmInvocations > 0) break;
    await new Promise(resolve => setTimeout(resolve, 20));
  } while (Date.now() < deadline);
  assert.ok(delivered.alarmInvocations > 0, "Workerd must actually deliver the alarm");
  assert.deepEqual(delivered.rows, []);
  assert.equal(delivered.alarm, null, "Drained SQL state must stop scheduling cleanup");

  const churnSizes = [];
  for (let cycle = 0; cycle < 3; cycle++) {
    const filled = await request("/fill-and-expire?account=churn");
    churnSizes.push(filled.databaseSize);
    await request("/alarm?account=churn");
    const churned = await request("/inspect?account=churn");
    assert.deepEqual(churned.rows, [], "Expired churn must be removed");
    assert.ok(churned.databaseSize <= 16 * 1024 * 1024, "Physical SQLite size must stay bounded after churn");
  }
  assert.ok(churnSizes.every(size => Number.isSafeInteger(size) && size <= 16 * 1024 * 1024));

  const original = await request("/schema/seed");
  await runtime.dispose();
  await start("bad");
  assert.equal((await runtime.dispatchFetch("http://sandbox/schema/inspect")).status, 500, "Broken upgrade must reject traffic");
  await runtime.dispose();
  await start();
  const restored = await request("/schema/inspect");
  assert.deepEqual(restored, original, "Failed schema deployment must preserve SQL, KV and schema marker");
  await runtime.dispose();
  await start("good");
  const upgraded = await request("/schema/inspect");
  assert.deepEqual(upgraded.schema, [{ version: 1 }, { version: 2 }]);
  assert.equal(upgraded.preferences[0].payload, "keep");
  assert.equal(upgraded.preferences[0].note, "upgraded");
  assert.equal(upgraded.kv, "keep-kv");
  assert.deepEqual(await request("/schema/inspect"), upgraded);
  await runtime.dispose();
  await start();
  assert.equal((await runtime.dispatchFetch("http://sandbox/schema/inspect")).status, 500, "Unsupported older code must reject the newer schema");
  await runtime.dispose();
  await start("good");
  assert.deepEqual(await request("/schema/inspect"), upgraded, "Forward recovery must preserve upgraded data");
  assert.equal(outboundCalls, 0);
  console.log(JSON.stringify({ result: "pass", checks: ["drizzle transaction rollback", "fresh schema", "persisted restart", "migration idempotence", "account isolation", "alarm preservation", "idle cleanup", "alarm rearm", "real alarm delivery", "drained alarm stop", "populated schema upgrade", "failed upgrade rollback", "unsupported downgrade rejection", "forward recovery", "external network blocked"] }));
} finally {
  await runtime?.dispose();
  await rm(directory, { recursive: true, force: true });
}
