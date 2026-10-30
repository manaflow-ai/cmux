import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";
import type { AuthedUser } from "../services/vms/auth";
import type { CmuxTuiAttachBundle } from "../services/vms/drivers/cmuxTuiDaemon";
import { VmProviderOperationError } from "../services/vms/errors";
import {
  HUGE_BLUE_INSPECTION_ENV,
  hugeBlueInspectionMode,
  hugeBlueInspectionView,
  type HugeBlueInspectionObservation,
} from "../services/vms/hugeBlueInspection";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";

// Read-only Huge Blue inspection (#21332): the pure state mapper, the
// workflow over fake repository and provider layers, and the route's auth
// and ownership contract. bun's mock.module is process-global, so every
// override delegates to the real implementation unless `active`.

const now = new Date("2026-10-17T00:00:00.000Z");
const FORBIDDEN_KEYS = ["token", "route", "invitation", "uri", "command", "networkAddresses", "providerMetadata", "expiresAtUnix"];

function bundle(overrides: Partial<CmuxTuiAttachBundle> = {}): CmuxTuiAttachBundle {
  return {
    daemonBuild: { commit: "abc123", remoteProtocol: 12, version: "0.13.0" },
    enrolled: false,
    trustedCarrier: false,
    invitation: null,
    ...overrides,
  };
}

function view(observation: HugeBlueInspectionObservation) {
  return hugeBlueInspectionView({ host: "fs-1", session: "cloud", observation, now });
}

function expectRedacted(value: unknown): void {
  const text = JSON.stringify(value);
  for (const key of FORBIDDEN_KEYS) expect(text).not.toContain(`"${key}"`);
  expect(text).not.toContain("cmux://");
  expect(text).not.toContain("secret");
}

describe("hugeBlueInspectionMode", () => {
  test("only an explicit value enables or disables; anything else is unconfigured", () => {
    expect(hugeBlueInspectionMode({})).toBe("unconfigured");
    expect(hugeBlueInspectionMode({ [HUGE_BLUE_INSPECTION_ENV]: "" })).toBe("unconfigured");
    expect(hugeBlueInspectionMode({ [HUGE_BLUE_INSPECTION_ENV]: "1" })).toBe("unconfigured");
    expect(hugeBlueInspectionMode({ [HUGE_BLUE_INSPECTION_ENV]: " Enabled " })).toBe("enabled");
    expect(hugeBlueInspectionMode({ [HUGE_BLUE_INSPECTION_ENV]: "disabled" })).toBe("disabled");
  });
});

describe("hugeBlueInspectionView", () => {
  test("disabled and unconfigured are distinct, explicit and non-retryable", () => {
    const disabled = view({ kind: "disabled" });
    expect(disabled).toMatchObject({ state: "disabled", reasonCode: "inspection_disabled", retryable: false });
    const unconfigured = view({ kind: "unconfigured" });
    expect(unconfigured).toMatchObject({ state: "unavailable", reasonCode: "adapter_not_configured", retryable: false });
    expect(unconfigured.capabilities).toEqual({ readOnlyInspection: true, daemonProtocol: null, trustedCarrier: false, enrolled: false });
  });

  test("a stopped machine or a failed probe is unavailable and retryable", () => {
    expect(view({ kind: "not_running" })).toMatchObject({ state: "unavailable", reasonCode: "target_not_running", retryable: true });
    expect(view({ kind: "probe_failed" })).toMatchObject({ state: "unavailable", reasonCode: "probe_failed", retryable: true });
  });

  test("a trusted-carrier daemon is admitted", () => {
    const result = view({ kind: "probed", bundle: bundle({ trustedCarrier: true }), deviceFingerprintGiven: false });
    expect(result).toEqual({
      host: "fs-1",
      session: "cloud",
      state: "admitted",
      reasonCode: "trusted_carrier",
      retryable: false,
      checkedAt: "2026-10-17T00:00:00.000Z",
      capabilities: { readOnlyInspection: true, daemonProtocol: 12, trustedCarrier: true, enrolled: false },
    });
  });

  test("an enrolled device is admitted only when the caller named that device", () => {
    expect(view({ kind: "probed", bundle: bundle({ enrolled: true }), deviceFingerprintGiven: true }))
      .toMatchObject({ state: "admitted", reasonCode: "device_enrolled" });
    expect(view({ kind: "probed", bundle: bundle({ enrolled: true }), deviceFingerprintGiven: false }))
      .toMatchObject({ state: "unenrolled", reasonCode: "device_not_enrolled", retryable: false });
  });

  test("a reachable daemon without carrier trust or enrollment is unenrolled", () => {
    const result = view({ kind: "probed", bundle: bundle(), deviceFingerprintGiven: true });
    expect(result).toMatchObject({ state: "unenrolled", reasonCode: "device_not_enrolled", retryable: false });
    expect(result.capabilities).toEqual({ readOnlyInspection: true, daemonProtocol: 12, trustedCarrier: false, enrolled: false });
  });

  test("missing, malformed or contradictory daemon evidence never reads as admitted", () => {
    const bad: Array<CmuxTuiAttachBundle["daemonBuild"]> = [
      null,
      { commit: "abc123", remoteProtocol: null, version: null },
      { commit: "abc123", remoteProtocol: 0, version: null },
      { commit: "abc123", remoteProtocol: -1, version: null },
      { commit: "abc123", remoteProtocol: 1.5, version: null },
      { commit: "abc123", remoteProtocol: "12" as unknown as number, version: null },
    ];
    for (const daemonBuild of bad) {
      const result = view({ kind: "probed", bundle: bundle({ daemonBuild, trustedCarrier: true, enrolled: true }), deviceFingerprintGiven: true });
      expect(result).toMatchObject({ state: "unavailable", reasonCode: "daemon_probe_unreadable", retryable: true });
      expect(result.capabilities).toEqual({ readOnlyInspection: true, daemonProtocol: null, trustedCarrier: false, enrolled: false });
    }
    const truthy = bundle({ trustedCarrier: "1" as unknown as boolean, enrolled: "yes" as unknown as boolean });
    expect(view({ kind: "probed", bundle: truthy, deviceFingerprintGiven: true }).state).toBe("unenrolled");
  });

  test("invitation material in the probe never reaches the view", () => {
    const leaky = bundle({
      trustedCarrier: true,
      invitation: { id: "inv-secret", uri: "cmux://enroll/inv-secret", expiresAtUnix: 1 } as unknown as CmuxTuiAttachBundle["invitation"],
    });
    expectRedacted(view({ kind: "probed", bundle: leaky, deviceFingerprintGiven: false }));
  });
});

// ---- Workflow over fake layers ----

function machineRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    visibility: "team",
    id: "row-1",
    userId: "user-1",
    billingTeamId: "team-1",
    ownerTeamId: "team-1",
    coderouterPoolId: null,
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: "fs-1",
    displayName: null,
    slug: "brave-otter",
    imageId: "sh-devbox",
    imageVersion: null,
    status: "running",
    idempotencyKey: null,
    createdAt: new Date("2026-09-01T00:00:00Z"),
    updatedAt: new Date("2026-09-01T00:00:00Z"),
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: { cmuxTuiContract: "snapshot-v2", secretRoute: "10.0.0.1" },
    networkPolicy: null,
    networkPolicyStatus: null,
    agentUpdates: null,
    ...overrides,
  };
}

function probeStdout(probe: string, devices: string, trusted: string): string {
  return ["__CMUX_PROBE__", probe, "__CMUX_DEVICES__", devices, "__CMUX_TRUSTED__", trusted, "__CMUX_END__"].join("\n");
}

function fakes(options: {
  row: CloudVmRow;
  exec?: () => Effect.Effect<{ exitCode: number; stdout: string; stderr: string }, VmProviderOperationError>;
}) {
  const execs: Array<{ vmId: string; command: string; asRoot?: boolean; providerMetadata?: Record<string, unknown> }> = [];
  const writes: string[] = [];
  const repo = {
    findUserVm: (input: { providerVmId: string }) =>
      Effect.succeed(input.providerVmId === options.row.providerVmId ? options.row : null),
    recordLease: () => Effect.sync(() => { writes.push("recordLease"); }),
    recordUsageEvent: () => Effect.sync(() => { writes.push("recordUsageEvent"); }),
  } as unknown as VmRepositoryShape;
  const provider = {
    exec: (_provider: string, vmId: string, command: string, execOptions?: { asRoot?: boolean; providerMetadata?: Record<string, unknown> }) => {
      execs.push({ vmId, command, asRoot: execOptions?.asRoot, providerMetadata: execOptions?.providerMetadata });
      return options.exec ? options.exec() : Effect.succeed({ exitCode: 0, stdout: "", stderr: "" });
    },
    openCmuxRemote: () => Effect.sync(() => { writes.push("openCmuxRemote"); throw new Error("inspection must not open an attach"); }),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, provider));
  return { execs, writes, layer };
}

const { inspectVmForHugeBlue } = await import("../services/vms/hugeBlueInspectionWorkflow");
const caller = { userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: "fs-1", now: () => now };

async function run(program: ReturnType<typeof inspectVmForHugeBlue>, layer: Layer.Layer<VmRepository | VmProviderGateway>) {
  return Effect.runPromiseExit((program as unknown as Effect.Effect<unknown, unknown, VmRepository | VmProviderGateway>).pipe(Effect.provide(layer)));
}

function failureTag(exit: Exit.Exit<unknown, unknown>): string | null {
  if (Exit.isSuccess(exit)) return null;
  const failure = Cause.failureOption(exit.cause);
  return failure._tag === "Some" ? ((failure.value as { _tag?: string })._tag ?? "unknown") : "die";
}

describe("inspectVmForHugeBlue", () => {
  test("a machine the caller cannot see is not found in every mode, before any probe", async () => {
    for (const mode of ["enabled", "disabled", "unconfigured"] as const) {
      const { execs, layer } = fakes({ row: machineRow() });
      const exit = await run(inspectVmForHugeBlue({ ...caller, providerVmId: "fs-other", mode }), layer);
      expect(failureTag(exit)).toBe("VmNotFoundError");
      expect(execs).toEqual([]);
    }
    const foreignTeam = fakes({ row: machineRow({ ownerTeamId: "team-2" }) });
    expect(failureTag(await run(inspectVmForHugeBlue({ ...caller, mode: "enabled" }), foreignTeam.layer))).toBe("VmNotFoundError");
    expect(foreignTeam.execs).toEqual([]);
  });

  test("disabled and unconfigured answer without touching the guest", async () => {
    for (const [mode, state, reasonCode] of [
      ["disabled", "disabled", "inspection_disabled"],
      ["unconfigured", "unavailable", "adapter_not_configured"],
    ] as const) {
      const { execs, layer } = fakes({ row: machineRow() });
      const exit = await run(inspectVmForHugeBlue({ ...caller, mode }), layer);
      expect(Exit.isSuccess(exit) && exit.value).toMatchObject({ state, reasonCode, retryable: false });
      expect(execs).toEqual([]);
    }
  });

  test("a paused machine is never woken by inspection", async () => {
    const { execs, layer } = fakes({ row: machineRow({ status: "paused" }) });
    const exit = await run(inspectVmForHugeBlue({ ...caller, mode: "enabled" }), layer);
    expect(Exit.isSuccess(exit) && exit.value).toMatchObject({ state: "unavailable", reasonCode: "target_not_running", retryable: true });
    expect(execs).toEqual([]);
  });

  test("a running trusted-carrier machine is admitted through the read-only bundle, and nothing is minted", async () => {
    const { execs, writes, layer } = fakes({
      row: machineRow(),
      exec: () => Effect.succeed({
        exitCode: 0,
        stdout: probeStdout('{"build_identity":"abc123","remote_protocol":12,"version":"0.13.0"}', "[]", "1"),
        stderr: "",
      }),
    });
    const exit = await run(inspectVmForHugeBlue({ ...caller, mode: "enabled" }), layer);
    expect(Exit.isSuccess(exit) && exit.value).toEqual({
      host: "fs-1",
      session: "cloud",
      state: "admitted",
      reasonCode: "trusted_carrier",
      retryable: false,
      checkedAt: "2026-10-17T00:00:00.000Z",
      capabilities: { readOnlyInspection: true, daemonProtocol: 12, trustedCarrier: true, enrolled: false },
    });
    expect(execs).toHaveLength(1);
    expect(execs[0]!.asRoot).toBe(true);
    expect(execs[0]!.command).not.toContain("remote enroll create");
    expect(execs[0]!.command).not.toContain("remote enroll approve");
    expect(writes).toEqual([]);
    expectRedacted(Exit.isSuccess(exit) ? exit.value : null);
    expect(JSON.stringify(Exit.isSuccess(exit) ? exit.value : null)).not.toContain("10.0.0.1");
  });

  test("an enrolled device fingerprint is checked against the daemon's device list", async () => {
    const stdout = probeStdout('{"build_identity":"abc123","remote_protocol":12}', '[{"fingerprint":"fp-1","revoked_at_unix":null}]', "0");
    const enrolled = fakes({ row: machineRow(), exec: () => Effect.succeed({ exitCode: 0, stdout, stderr: "" }) });
    const admitted = await run(inspectVmForHugeBlue({ ...caller, mode: "enabled", deviceFingerprint: "fp-1" }), enrolled.layer);
    expect(Exit.isSuccess(admitted) && admitted.value).toMatchObject({ state: "admitted", reasonCode: "device_enrolled" });
    const other = fakes({ row: machineRow(), exec: () => Effect.succeed({ exitCode: 0, stdout, stderr: "" }) });
    const unenrolled = await run(inspectVmForHugeBlue({ ...caller, mode: "enabled", deviceFingerprint: "fp-2" }), other.layer);
    expect(Exit.isSuccess(unenrolled) && unenrolled.value).toMatchObject({ state: "unenrolled", reasonCode: "device_not_enrolled" });
  });

  test("a failed, non-zero or garbled probe fails closed", async () => {
    const cases = [
      () => Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "exec", cause: new Error("offline") })),
      () => Effect.succeed({ exitCode: 3, stdout: "", stderr: "" }),
    ];
    for (const exec of cases) {
      const { layer } = fakes({ row: machineRow(), exec });
      const exit = await run(inspectVmForHugeBlue({ ...caller, mode: "enabled" }), layer);
      expect(Exit.isSuccess(exit) && exit.value).toMatchObject({ state: "unavailable", reasonCode: "probe_failed", retryable: true });
    }
    const garbled = fakes({ row: machineRow(), exec: () => Effect.succeed({ exitCode: 0, stdout: "garbage 1", stderr: "" }) });
    const exit = await run(inspectVmForHugeBlue({ ...caller, mode: "enabled" }), garbled.layer);
    expect(Exit.isSuccess(exit) && exit.value).toMatchObject({ state: "unavailable", reasonCode: "daemon_probe_unreadable" });
  });
});

// ---- Route contract ----

let active = false;
let authedUser: AuthedUser | null = null;
const programs: Array<Record<string, unknown>> = [];
let routeResult: { ok: true; value: unknown } | { ok: false; response: Response } = { ok: true, value: {} };

const realAuth = await import("../services/vms/auth");
const realVerifyRequest = realAuth.verifyRequest;
const realWorkflowModule = await import("../services/vms/hugeBlueInspectionWorkflow");
const realInspect = realWorkflowModule.inspectVmForHugeBlue;
const realRouteWorkflow = await import("../services/vms/routeWorkflow");
const realRunVmRoute = realRouteWorkflow.runVmRoute;

mock.module("../services/vms/auth", () => ({
  ...realAuth,
  verifyRequest: ((request: Request, options?: unknown) =>
    active ? Promise.resolve(authedUser) : realVerifyRequest(request, options as never)) as typeof realVerifyRequest,
}));

mock.module("../services/vms/hugeBlueInspectionWorkflow", () => ({
  ...realWorkflowModule,
  inspectVmForHugeBlue: ((input: Parameters<typeof realInspect>[0]) => {
    if (!active) return realInspect(input);
    programs.push(input as Record<string, unknown>);
    return { sentinel: "inspect" } as unknown as ReturnType<typeof realInspect>;
  }) as typeof realInspect,
}));

mock.module("../services/vms/routeWorkflow", () => ({
  ...realRouteWorkflow,
  runVmRoute: (async (program: unknown, options?: unknown) => {
    if (!active) return realRunVmRoute(program as never, options as never);
    expect((program as { sentinel?: string }).sentinel).toBe("inspect");
    return routeResult;
  }) as typeof realRunVmRoute,
}));

const route = await import("../app/api/vm/[id]/huge-blue-inspection/route");

const user: AuthedUser = {
  id: "user-1",
  isAnonymous: false,
  displayName: "Member",
  primaryEmail: "member@example.com",
  billingCustomerType: "team",
  billingTeamId: "team-1",
  selectedTeamId: "team-1",
  teams: [{ id: "team-1", displayName: "cmux", billingPlanId: "pro", billingSeats: 3 }],
  teamIds: ["team-1"],
  userBillingPlanId: null,
  billingPlanId: "pro",
  billingSeats: 3,
};

function request(query = ""): Request {
  return new Request(`https://cmux.test/api/vm/fs-1/huge-blue-inspection${query}`, {
    method: "GET",
    headers: { authorization: "Bearer access-token", "x-stack-refresh-token": "refresh-token" },
  });
}

const params = { params: Promise.resolve({ id: "fs-1" }) };

describe("GET /api/vm/[id]/huge-blue-inspection", () => {
  const originalMode = process.env[HUGE_BLUE_INSPECTION_ENV];
  beforeAll(() => {
    active = true;
  });
  afterAll(() => {
    active = false;
    if (originalMode === undefined) delete process.env[HUGE_BLUE_INSPECTION_ENV];
    else process.env[HUGE_BLUE_INSPECTION_ENV] = originalMode;
  });
  beforeEach(() => {
    authedUser = user;
    programs.length = 0;
    routeResult = { ok: true, value: view({ kind: "unconfigured" }) };
    delete process.env[HUGE_BLUE_INSPECTION_ENV];
  });

  test("an unauthenticated request never reaches the workflow", async () => {
    authedUser = null;
    expect((await route.GET(request(), params)).status).toBe(401);
    expect(programs).toEqual([]);
  });

  test("hands the caller's scope, the machine id and the deployment mode to the workflow", async () => {
    process.env[HUGE_BLUE_INSPECTION_ENV] = "enabled";
    const response = await route.GET(request("?deviceFingerprint=fp-1"), params);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(view({ kind: "unconfigured" }));
    expect(programs).toEqual([{
      userId: "user-1",
      billingTeamId: "team-1",
      teamIds: ["team-1"],
      providerVmId: "fs-1",
      mode: "enabled",
      deviceFingerprint: "fp-1",
    }]);
  });

  test("an unset switch is passed as unconfigured", async () => {
    await route.GET(request(), params);
    expect(programs[0]).toMatchObject({ mode: "unconfigured", deviceFingerprint: undefined });
  });

  test("a malformed device fingerprint is refused before the workflow", async () => {
    const response = await route.GET(request("?deviceFingerprint=bad%20fp%3B%20rm"), params);
    expect(response.status).toBe(400);
    expect((await response.json()).error).toBe("invalid_request");
    expect(programs).toEqual([]);
  });

  test("a machine the caller cannot see answers the workflow's 404", async () => {
    routeResult = {
      ok: false,
      response: new Response(JSON.stringify({ error: "vm_not_found" }), { status: 404, headers: { "content-type": "application/json" } }),
    };
    const response = await route.GET(request(), params);
    expect(response.status).toBe(404);
    expect((await response.json()).error).toBe("vm_not_found");
  });
});
