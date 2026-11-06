/**
 * Production smoke of the product create path, the one cmux-platform's Cloud driver takes for every NEXT Cloud
 * machine (cmux-platform src/server/cloud/vmapi/CloudProvider.ts): a product team (no DEV_TEST_TENANT_IDS entry,
 * so the never-pause -1 idle default), the approved boot image and no idleTimeoutSeconds. The service-key leg of
 * smoke.ts runs on a dev/test team with idleTimeoutSeconds 60, so it passed while every product create answered
 * 503 (cmux#35012, 2026-11-04).
 *
 * It holds no key. In GitHub Actions (id-token: write) it asks GitHub for the job's OIDC token with the Worker's
 * origin as audience, and the Worker maps it to its CMUX_VM_CI_TRUST row (src/auth/ci-trust.ts): ci-product-smoke,
 * which acts only for its own team, on its own labelled VMs, at most 2 of them, each paused after 15 minutes and
 * deleted once stopped. GitHub's tokens live minutes, so a fresh one is fetched whenever the last is a minute old.
 *
 *   CMUX_VM_SMOKE_URL=https://vm.cmux.dev [CMUX_VM_SMOKE_IMAGE=<id> CMUX_VM_SMOKE_IMAGE_REVISION=<rev>] \
 *     bun scripts/smoke-product.ts
 *
 * Without CMUX_VM_SMOKE_IMAGE it boots the first image GET /v1/vm-images lists for the caller. The VM is deleted
 * by its exact id, also when a step fails. No token is ever printed.
 */
const base = process.env["CMUX_VM_SMOKE_URL"] ?? "";
const tokenUrl = process.env["ACTIONS_ID_TOKEN_REQUEST_URL"] ?? "";
const tokenRequestToken = process.env["ACTIONS_ID_TOKEN_REQUEST_TOKEN"] ?? "";
const imageId = process.env["CMUX_VM_SMOKE_IMAGE"] ?? "";
const imageRevision = process.env["CMUX_VM_SMOKE_IMAGE_REVISION"] ?? "";
if (base === "") {
  console.error("CMUX_VM_SMOKE_URL is required");
  process.exit(2);
}
if (tokenUrl === "" || tokenRequestToken === "") {
  console.error("No GitHub OIDC token: run this in a GitHub Actions job with permissions id-token: write");
  process.exit(2);
}
const origin = new URL(base);
if (origin.protocol !== "https:" || origin.pathname !== "/") {
  console.error("CMUX_VM_SMOKE_URL must be an https origin");
  process.exit(2);
}
const audience = origin.origin;

let cachedToken: { readonly value: string; readonly at: number } | undefined;
const oidcToken = async (): Promise<string> => {
  if (cachedToken !== undefined && Date.now() - cachedToken.at < 60_000) return cachedToken.value;
  const url = new URL(tokenUrl);
  url.searchParams.set("audience", audience);
  const response = await fetch(url, { headers: { authorization: `Bearer ${tokenRequestToken}` }, signal: AbortSignal.timeout(30_000) });
  const body: unknown = await response.json().catch(() => null);
  const value = typeof body === "object" && body !== null ? Reflect.get(body, "value") : undefined;
  if (!response.ok || typeof value !== "string") throw new Error(`GitHub OIDC token request answered ${response.status}`);
  cachedToken = { value, at: Date.now() };
  return value;
};

// The attempt too: a re-run of the job must not replay the first attempt's create (deleted by then) under its key.
const runId = process.env["GITHUB_RUN_ID"] === undefined ? `local-${Date.now()}` : `${process.env["GITHUB_RUN_ID"]}-${process.env["GITHUB_RUN_ATTEMPT"] ?? "1"}`;
const STEP_TIMEOUT_MS = 120_000;
const BOOT_TIMEOUT_MS = 300_000;

const call = async (method: string, path: string, body?: unknown, headers: Record<string, string> = {}) => {
  const response = await fetch(new URL(path, origin), {
    method,
    headers: {
      authorization: `Bearer ${await oidcToken()}`,
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

  // A run cancelled before its cleanup leaves its VM behind: paused by the run cap and deleted upstream, but its row
  // still counts against the 2-VM quota until deleted here. The principal sees only its own VMs and the job's
  // concurrency group runs one smoke at a time, so every VM listed is a leftover; deleting a gone one forgets it.
  const leftovers = await call("GET", "/v1/vms");
  expectStatus("list own VMs", leftovers.status, 200, leftovers.body);
  const listed = field(leftovers.body, "items");
  for (const item of Array.isArray(listed) ? listed : []) {
    const leftover = field(item, "id");
    if (typeof leftover !== "string") continue;
    const removed = await call("DELETE", `/v1/vms/${leftover}`);
    if (removed.status !== 204 && removed.status !== 404) throw new Error(`could not delete leftover ${leftover}: ${removed.status} ${JSON.stringify(removed.body)}`);
    console.log(`ok  deleted leftover ${leftover} (${removed.status})`);
  }

  let image = { id: imageId, revision: imageRevision };
  if (image.id === "") {
    const catalog = await call("GET", "/v1/vm-images");
    expectStatus("boot image catalog", catalog.status, 200, catalog.body);
    const items = field(catalog.body, "items");
    const first: unknown = Array.isArray(items) ? items[0] : undefined;
    const id = field(first, "id");
    const revision = field(first, "revision");
    if (typeof id !== "string" || typeof revision !== "string") throw new Error(`no approved boot image for this caller: ${JSON.stringify(catalog.body)}`);
    image = { id, revision };
  }
  console.log(`    boot image ${image.id}@${image.revision}`);

  // The body cmux-platform's driver sends: labels, the approved image, and no idleTimeoutSeconds or autoDeleteSeconds.
  const name = `smoke-product-${runId}`.slice(0, 63);
  const created = await call(
    "POST",
    "/v1/vms",
    { displayName: name, labels: { role: "cloud", cmux_next_team: "cmux-vm-product-smoke", purpose: "smoke" }, image },
    { "idempotency-key": `smoke-product-${runId}` },
  );
  // Record any VM id before judging the status, so the cleanup below deletes a VM a failed create still made.
  const id = field(created.body, "id");
  if (typeof id === "string" && /^vm_[0-9a-z]{26}$/.test(id)) vmId = id;
  expectStatus("product create (never-pause, approved image)", created.status, 201, created.body);
  if (vmId === null) throw new Error(`create returned no VM id: ${JSON.stringify(created.body)}`);
  console.log(`    created ${vmId} in ${Date.now() - started} ms`);
  const idle = field(created.body, "idleTimeoutSeconds");
  if (idle !== null && idle !== undefined && !(typeof idle === "number" && idle < 0)) throw new Error(`a product create got idle timeout ${String(idle)}, not never-pause`);
  console.log("ok  never-pause idle timeout");
  const bootImage = field(created.body, "bootImage");
  if (field(bootImage, "id") !== image.id || field(bootImage, "revision") !== image.revision) {
    throw new Error(`create receipt names boot image ${JSON.stringify(bootImage)}, not ${image.id}@${image.revision}`);
  }
  console.log("ok  boot image receipt");
  // The CI trust row's backstop (the Worker forces it and its tests check the provider request): if this job dies
  // before its cleanup, the VM pauses within the run cap and is deleted. Reported, not asserted: the receipt shows
  // what the provider echoes.
  console.log(`    receipt: maxRunSeconds ${String(field(created.body, "maxRunSeconds"))}, autoDeleteSeconds ${String(field(created.body, "autoDeleteSeconds"))}`);

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
