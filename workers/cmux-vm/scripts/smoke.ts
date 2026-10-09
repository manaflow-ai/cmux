/**
 * Live smoke test of a deployed cmux VM API: create, exec, pause, delete by
 * exact id, on the dedicated test tenant whose API key is in the environment.
 * CI runs it after each staging deploy (.github/workflows/cmux-vm.yml).
 *
 *   CMUX_VM_SMOKE_URL=https://vm-staging.cmux.dev \
 *   CMUX_VM_SMOKE_API_KEY=cmuxvm_sk_... bun scripts/smoke.ts
 *
 * The VM it creates is always deleted by its exact id, also when a step fails,
 * and is created with idleTimeoutSeconds 60 and autoDeleteSeconds 3600 as
 * backstops. The key is read from the environment and never printed.
 *
 * With CMUX_VM_SMOKE_API_KEY_B (a key of a second tenant, same scopes) it checks that
 * the second tenant gets 404 for every read and mutation on the first
 * tenant's VM, and that the VM is absent from the second tenant's list.
 *
 * API key management (cx-b4h.12): the smoke key holds no admin scope, so list,
 * create and revoke of API keys must each answer 403 (the route is live, past
 * the schema gate, and refuses a non-admin before reading any key).
 *
 * With CMUX_VM_SMOKE_SERVICE_KEY and CMUX_VM_SMOKE_SERVICE_TEAM (a service key
 * limited to role=chief VMs and to that team, cx-b4h.13) it checks: 401
 * without X-Cmux-Team-Id, 403 for a VM without role=chief, 404 on the smoke
 * tenant's VM, then create role=chief, exec, pause and delete by exact id.
 */
const base = process.env["CMUX_VM_SMOKE_URL"];
const key = process.env["CMUX_VM_SMOKE_API_KEY"];
const keyB = process.env["CMUX_VM_SMOKE_API_KEY_B"] ?? "";
const serviceKey = process.env["CMUX_VM_SMOKE_SERVICE_KEY"] ?? "";
const serviceTeam = process.env["CMUX_VM_SMOKE_SERVICE_TEAM"] ?? "";
if (base === undefined || base === "" || key === undefined || key === "") {
  console.error("CMUX_VM_SMOKE_URL and CMUX_VM_SMOKE_API_KEY are required");
  process.exit(2);
}
const origin = new URL(base);
if (origin.protocol !== "https:" || origin.pathname !== "/") {
  console.error("CMUX_VM_SMOKE_URL must be an https origin");
  process.exit(2);
}

const runId = process.env["GITHUB_RUN_ID"] ?? `local-${Date.now()}`;
const STEP_TIMEOUT_MS = 120_000;

const call = async (method: string, path: string, body?: unknown, headers: Record<string, string> = {}, bearer: string = key) => {
  const response = await fetch(new URL(path, origin), {
    method,
    headers: {
      authorization: `Bearer ${bearer}`,
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

/** Polls the VM until it reaches `state` or the step times out. */
const waitForState = async (vmId: string, state: string, as: { readonly bearer: string; readonly headers: Record<string, string> } = { bearer: key, headers: {} }) => {
  const deadline = Date.now() + STEP_TIMEOUT_MS;
  for (;;) {
    const read = await call("GET", `/v1/vms/${vmId}`, undefined, as.headers, as.bearer);
    expectStatus(`get ${vmId}`, read.status, 200, read.body);
    if (field(read.body, "state") === state) return;
    if (Date.now() > deadline) throw new Error(`VM ${vmId} did not reach ${state}; last state ${String(field(read.body, "state"))}`);
    await new Promise((resolve) => setTimeout(resolve, 3_000));
  }
};

let vmId: string | null = null;
let serviceVmId: string | null = null;
let failed = false;
const asService = { bearer: serviceKey, headers: { "x-cmux-team-id": serviceTeam } };
try {
  const health = await call("GET", "/healthz");
  expectStatus("health", health.status, 200, health.body);

  const created = await call(
    "POST",
    "/v1/vms",
    { displayName: `smoke ${runId}`, idleTimeoutSeconds: 60, autoDeleteSeconds: 3600, labels: { purpose: "smoke", run: runId.slice(0, 63) } },
    { "idempotency-key": `smoke-${runId}` },
  );
  expectStatus("create", created.status, 201, created.body);
  const id = field(created.body, "id");
  if (typeof id !== "string" || !/^vm_[0-9a-z]{26}$/.test(id)) throw new Error(`create returned no VM id: ${JSON.stringify(created.body)}`);
  vmId = id;
  console.log(`    created ${vmId}`);

  await waitForState(vmId, "running");

  if (keyB !== "") {
    // Another tenant must not learn that the VM exists: every call is 404.
    const foreign: ReadonlyArray<readonly [string, string, unknown]> = [
      ["GET", `/v1/vms/${vmId}`, undefined],
      ["POST", `/v1/vms/${vmId}/exec`, { command: "echo leaked", timeoutMs: 10_000 }],
      ["POST", `/v1/vms/${vmId}/pause`, undefined],
      ["POST", `/v1/vms/${vmId}/stop`, undefined],
      ["POST", `/v1/vms/${vmId}/fork`, {}],
      ["DELETE", `/v1/vms/${vmId}`, undefined],
    ];
    for (const [method, path, body] of foreign) {
      const response = await call(method, path, body, {}, keyB);
      expectStatus(`tenant B ${method} ${path.replace(vmId, "<vm>")}`, response.status, 404, response.body);
    }
    const listB = await call("GET", "/v1/vms", undefined, {}, keyB);
    expectStatus("tenant B list", listB.status, 200, listB.body);
    if (JSON.stringify(listB.body).includes(vmId)) throw new Error("tenant B list shows tenant A's VM");
    console.log("ok  tenant B list does not show the VM");
    // The VM is untouched by the refused calls.
    await waitForState(vmId, "running");
  }

  const exec = await call("POST", `/v1/vms/${vmId}/exec`, { command: "echo cmux-vm-smoke", timeoutMs: 30_000 });
  expectStatus("exec", exec.status, 200, exec.body);
  if (field(exec.body, "exitCode") !== 0 || field(exec.body, "stdout") !== "cmux-vm-smoke\n") {
    throw new Error(`exec returned ${JSON.stringify(exec.body)}`);
  }

  const paused = await call("POST", `/v1/vms/${vmId}/pause`);
  expectStatus("pause", paused.status, 200, paused.body);
  await waitForState(vmId, "paused");

  // API key management needs the admin scope; the smoke key has none.
  const keysList = await call("GET", "/v1/api-keys");
  expectStatus("api-keys list without admin", keysList.status, 403, keysList.body);
  const keysCreate = await call("POST", "/v1/api-keys", { name: "smoke", scopes: ["vm:read"] });
  expectStatus("api-keys create without admin", keysCreate.status, 403, keysCreate.body);
  const keysRevoke = await call("DELETE", "/v1/api-keys/vmk_00000000000000000000000000");
  expectStatus("api-keys revoke without admin", keysRevoke.status, 403, keysRevoke.body);

  if (serviceKey !== "" && serviceTeam !== "") {
    const noTeam = await call("GET", "/v1/vms", undefined, {}, serviceKey);
    expectStatus("service without team header", noTeam.status, 401, noTeam.body);
    const unlabelled = await call("POST", "/v1/vms", { idleTimeoutSeconds: 60, autoDeleteSeconds: 3600 }, asService.headers, serviceKey);
    expectStatus("service create without role=chief", unlabelled.status, 403, unlabelled.body);
    const foreign = await call("GET", `/v1/vms/${vmId}`, undefined, asService.headers, serviceKey);
    expectStatus("service GET the smoke tenant's VM", foreign.status, 404, foreign.body);

    const chief = await call(
      "POST",
      "/v1/vms",
      { displayName: `smoke chief ${runId}`, idleTimeoutSeconds: 60, autoDeleteSeconds: 3600, labels: { role: "chief", purpose: "smoke" } },
      { ...asService.headers, "idempotency-key": `smoke-chief-${runId}` },
      serviceKey,
    );
    expectStatus("service create role=chief", chief.status, 201, chief.body);
    const chiefId = field(chief.body, "id");
    if (typeof chiefId !== "string" || !/^vm_[0-9a-z]{26}$/.test(chiefId)) throw new Error(`service create returned no VM id: ${JSON.stringify(chief.body)}`);
    serviceVmId = chiefId;
    console.log(`    created ${serviceVmId}`);
    await waitForState(serviceVmId, "running", asService);
    const chiefExec = await call("POST", `/v1/vms/${serviceVmId}/exec`, { command: "echo cmux-vm-chief", timeoutMs: 30_000 }, asService.headers, serviceKey);
    expectStatus("service exec", chiefExec.status, 200, chiefExec.body);
    const chiefList = await call("GET", "/v1/vms", undefined, asService.headers, serviceKey);
    expectStatus("service list", chiefList.status, 200, chiefList.body);
    if (!JSON.stringify(chiefList.body).includes(serviceVmId)) throw new Error("service list does not show its chief VM");
    const ownerSees = await call("GET", `/v1/vms/${serviceVmId}`);
    expectStatus("smoke tenant GET the service team's VM", ownerSees.status, 404, ownerSees.body);
    const chiefPause = await call("POST", `/v1/vms/${serviceVmId}/pause`, undefined, asService.headers, serviceKey);
    expectStatus("service pause", chiefPause.status, 200, chiefPause.body);
  }
} catch (error) {
  failed = true;
  console.error(`FAIL ${error instanceof Error ? error.message : String(error)}`);
} finally {
  if (serviceVmId !== null) {
    const deleted = await call("DELETE", `/v1/vms/${serviceVmId}`, undefined, asService.headers, serviceKey);
    try {
      expectStatus(`service delete ${serviceVmId}`, deleted.status, 204, deleted.body);
      const gone = await call("GET", `/v1/vms/${serviceVmId}`, undefined, asService.headers, serviceKey);
      expectStatus(`service get after delete ${serviceVmId}`, gone.status, 404, gone.body);
    } catch (error) {
      failed = true;
      console.error(`FAIL ${error instanceof Error ? error.message : String(error)}; delete ${serviceVmId} by hand`);
    }
  }
  if (vmId !== null) {
    const deleted = await call("DELETE", `/v1/vms/${vmId}`);
    try {
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
