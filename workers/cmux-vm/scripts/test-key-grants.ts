/** service-key-grants.json grants only known scopes, never admin, and apply-key-grants.sh merges them into the matching entries only. */
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Schema } from "effect";
import { parseServiceKeys } from "../src/auth/service-keys.ts";
import { Scope } from "../src/domain/scopes.ts";

const script = fileURLToPath(new URL("./apply-key-grants.sh", import.meta.url));
const grants: Record<string, string[]> = JSON.parse(readFileSync(new URL("../service-key-grants.json", import.meta.url), "utf8"));
const apply = (keys: unknown, grantsFile?: string) =>
  Bun.spawnSync(["bash", script, ...(grantsFile ? [grantsFile] : [])], { stdin: new TextEncoder().encode(JSON.stringify(keys)), stdout: "pipe", stderr: "pipe" });
const entry = (id: string, scopes: string[]) => ({ id, sha256: String(id.length).padStart(64, "0"), scopes, labels: { role: "cloud" }, teams: null });

for (const [id, scopes] of Object.entries(grants)) {
  assert.match(id, /^[a-z][a-z0-9-]{0,39}$/u);
  for (const scope of scopes) {
    assert.ok(Schema.is(Scope)(scope), `${id}: unknown scope ${scope}`);
    assert.notEqual(scope, "admin");
  }
}

const dev = entry("cloud-platform-dev", ["vm:read", "mesh:read", "acl:read"]);
const chief = entry("cloud-chief", ["vm:read"]);
const merged = apply([dev, chief]);
assert.equal(merged.exitCode, 0, merged.stderr.toString());
const keys = JSON.parse(merged.stdout.toString());
assert.deepEqual(keys, [{ ...dev, scopes: ["acl:read", "acl:write", "mesh:read", "vm:read"] }, chief]);
const parsed = parseServiceKeys(JSON.stringify(keys));
assert.ok(parsed.ok);
assert.ok(parsed.keys[0]?.scopes.has("acl:write"));

const dir = mkdtempSync(join(tmpdir(), "key-grants-"));
for (const [name, body] of [["admin", { x: ["admin"] }], ["empty", { x: [] }], ["list", ["acl:read"]]] as const) {
  const file = join(dir, `${name}.json`);
  writeFileSync(file, JSON.stringify(body));
  assert.notEqual(apply([entry("x", ["vm:read"])], file).exitCode, 0, `${name} grant file was accepted`);
}
const notList = apply("cmuxvm_sk_leak");
assert.notEqual(notList.exitCode, 0, "a JSON string was accepted as the key list");
assert.ok(!notList.stderr.toString().includes("leak"), "the key list leaked into stderr");
for (const raw of ["[] []", '[{"id":"a"}] garbage']) {
  const r = Bun.spawnSync(["bash", script], { stdin: new TextEncoder().encode(raw), stdout: "pipe", stderr: "pipe" });
  assert.notEqual(r.exitCode, 0, `${raw} was accepted`);
  assert.equal(r.stdout.toString(), "", `${raw} printed partial output`);
}
console.log("service key grants: ok");
