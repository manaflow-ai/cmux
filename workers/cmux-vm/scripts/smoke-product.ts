/**
 * Production smoke of the product create path, the one cmux-platform's Cloud driver takes for every NEXT Cloud
 * machine (cmux-platform src/server/cloud/vmapi/CloudProvider.ts): the cloud-platform-production service key,
 * a product team (no DEV_TEST_TENANT_IDS entry, so the never-pause -1 idle default), the approved boot image and
 * no idleTimeoutSeconds. The service-key leg of smoke.ts runs on a dev/test team with idleTimeoutSeconds 60, so it
 * passed while every product create answered 503 (cmux#35012, 2026-11-04).
 *
 *   CMUX_VM_SMOKE_URL=https://vm.cmux.dev \
 *   CMUX_VM_SMOKE_PLATFORM_KEY=cmuxvm_sk_... CMUX_VM_SMOKE_PRODUCT_TEAM=<stack team id> \
 *   [CMUX_VM_SMOKE_IMAGE=<id> CMUX_VM_SMOKE_IMAGE_REVISION=<rev>] bun scripts/smoke-product.ts
 *
 * Without CMUX_VM_SMOKE_IMAGE it boots the first image GET /v1/vm-images lists for the key (production approves
 * exactly one image, for cloud-platform-production). The VM is deleted by its exact id, also when a step fails.
 * The key is read from the environment and never printed.
 */
const base = process.env["CMUX_VM_SMOKE_URL"] ?? "";
const key = process.env["CMUX_VM_SMOKE_PLATFORM_KEY"] ?? "";
const team = process.env["CMUX_VM_SMOKE_PRODUCT_TEAM"] ?? "";
const imageId = process.env["CMUX_VM_SMOKE_IMAGE"] ?? "";
const imageRevision = process.env["CMUX_VM_SMOKE_IMAGE_REVISION"] ?? "";
if (base === "" || key === "" || team === "") {
  console.error("CMUX_VM_SMOKE_URL, CMUX_VM_SMOKE_PLATFORM_KEY and CMUX_VM_SMOKE_PRODUCT_TEAM are required");
  process.exit(2);
}
const origin = new URL(base);
if (origin.protocol !== "https:" || origin.pathname !== "/") {
  console.error("CMUX_VM_SMOKE_URL must be an https origin");
  process.exit(2);
}

const runId = process.env["GITHUB_RUN_ID"] ?? `local-${Date.now()}`;
const STEP_TIMEOUT_MS = 120_000;
const BOOT_TIMEOUT_MS = 300_000;

const call = async (method: string, path: string, body?: unknown, headers: Record<string, string> = {}) => {
  const response = await fetch(new URL(path, origin), {
    method,
    headers: {
      authorization: `Bearer ${key}`,
      "x-cmux-team-id": team,
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...headers,
    },
    body: body === undefined ? null : JSON.stringify(body),
    signal: AbortSignal.timeout(STEP_TIMEOUT_MS),
  });
  const text = await response.text();
  let parsed: unknown = null;
  try {
    parsed = text === "" ? null : JSON.parse(text);
  } catch {
    parsed = text;
  }
  return { status: response.status, body: parsed };
};

const field = (value: unknown, name: string): unknown =>
  typeof value === "object" && value !== null && name in value ? Reflect.get(value, name) : undefined;

const expectStatus = (step: string, actual: number, expected: number, body: unknown) => {
  if (actual !== expected) throw new Error(`${step}: expected ${expected}, got ${actual}: ${JSON.stringify(body)}`);
  console.log(`ok  ${step} (${actual})`);
};

let vmId: string | null = null;
let failed = false;
const started = Date.now();
try {
  const health = await call("GET", "/healthz");
  expectStatus("health", health.status, 200, health.body);

  let image = { id: imageId, revision: imageRevision };
  if (image.id === "") {
    const catalog = await call("GET", "/v1/vm-images");
    expectStatus("boot image catalog", catalog.status, 200, catalog.body);
    const items = field(catalog.body, "items");
    const first: unknown = Array.isArray(items) ? items[0] : undefined;
    const id = field(first, "id");
    const revision = field(first, "revision");
    if (typeof id !== "string" || typeof revision !== "string") throw new Error(`no approved boot image for this key: ${JSON.stringify(catalog.body)}`);
    image = { id, revision };
  }
  console.log(`    boot image ${image.id}@${image.revision}`);

  // The body cmux-platform's driver sends: labels, the approved image, and no idleTimeoutSeconds or autoDeleteSeconds.
  const name = `smoke-product-${runId}`.slice(0, 63);
  const created = await call(
    "POST",
    "/v1/vms",
    { displayName: name, labels: { role: "cloud", cmux_next_team: team, purpose: "smoke" }, image },
    { "idempotency-key": `smoke-product-${runId}` },
  );
  expectStatus("product create (never-pause, approved image)", created.status, 201, created.body);
  const id = field(created.body, "id");
  if (typeof id !== "string" || !/^vm_[0-9a-z]{26}$/.test(id)) throw new Error(`create returned no VM id: ${JSON.stringify(created.body)}`);
  vmId = id;
  console.log(`    created ${vmId} in ${Date.now() - started} ms`);
  const idle = field(created.body, "idleTimeoutSeconds");
  if (idle !== null && idle !== undefined && !(typeof idle === "number" && idle < 0)) throw new Error(`a product create got idle timeout ${String(idle)}, not never-pause`);
  console.log("ok  never-pause idle timeout");
  const bootImage = field(created.body, "bootImage");
  if (field(bootImage, "id") !== image.id || field(bootImage, "revision") !== image.revision) {
    throw new Error(`create receipt names boot image ${JSON.stringify(bootImage)}, not ${image.id}@${image.revision}`);
  }
  console.log("ok  boot image receipt");

  const deadline = Date.now() + BOOT_TIMEOUT_MS;
  for (;;) {
    const read = await call("GET", `/v1/vms/${vmId}`);
    expectStatus(`get ${vmId}`, read.status, 200, read.body);
    const state = field(read.body, "state");
    if (state === "running") break;
    if (state === "stopped") throw new Error(`VM ${vmId} stopped while booting: ${JSON.stringify(read.body)}`);
    if (Date.now() > deadline) throw new Error(`VM ${vmId} did not reach running; last state ${String(state)}`);
    await new Promise((resolve) => setTimeout(resolve, 3_000));
  }
  console.log(`ok  running after ${Date.now() - started} ms`);

  const exec = await call("POST", `/v1/vms/${vmId}/exec`, { command: "echo cmux-vm-product-smoke", timeoutMs: 30_000 });
  expectStatus("exec", exec.status, 200, exec.body);
  if (field(exec.body, "exitCode") !== 0 || field(exec.body, "stdout") !== "cmux-vm-product-smoke\n") {
    throw new Error(`exec returned ${JSON.stringify(exec.body)}`);
  }
} catch (error) {
  failed = true;
  console.error(`FAIL ${error instanceof Error ? error.message : String(error)}`);
} finally {
  if (vmId !== null) {
    try {
      const deleted = await call("DELETE", `/v1/vms/${vmId}`);
      expectStatus(`delete ${vmId}`, deleted.status, 204, deleted.body);
      const gone = await call("GET", `/v1/vms/${vmId}`);
      expectStatus(`get after delete ${vmId}`, gone.status, 404, gone.body);
    } catch (error) {
      failed = true;
      console.error(`FAIL ${error instanceof Error ? error.message : String(error)}; delete ${vmId} by hand`);
    }
  }
}
process.exit(failed ? 1 : 0);
