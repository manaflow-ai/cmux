/**
 * Concurrent VM attaches to one mesh share the ACL apply that covers them.
 *
 * Every attach used to run its own full read-compile-apply under the mesh's one
 * writer lock, so N attaches by a team (one mesh per tenant) queued for N
 * applies: on staging 10 concurrent Cloud creates answered as a staircase from
 * 7.8 s to 28.5 s, ~2.3 s per step. An apply compiles the mesh's stored state,
 * so it covers every attach whose member row was written before it read; those
 * attaches answer once it lands, without an apply of their own.
 */
import { Duration, Effect, Layer, TestClock, TestContext } from "effect";
import { type AuditEntry, AuditStore } from "../../src/db/stores.ts";
import { timedAttach } from "../../src/handlers/mesh.ts";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { TenantId } from "../../src/lib/ids.ts";
import { memoryLimitsLayer, TenantLimits, type TenantLimitsService } from "../../src/limits/service.ts";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { enrollBody, makeInstallKey } from "../support/mesh-signing.ts";

const TEAM = "team_alpha";
const KEY = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
/** What one apply's read-compile costs here: each apply reads the mesh's ACL once, and that read takes this long. */
const APPLY_MS = 1_000;
const ATTACHES = 10;

let h: Awaited<ReturnType<typeof makeHarness>>;
let limits: TenantLimitsService;
beforeEach(async () => {
  limits = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer()));
  h = await makeHarness({ limits: Layer.succeed(TenantLimits, limits) });
});
afterEach(async () => { await h.dispose(); });

const record = (v: unknown): Record<string, unknown> => (typeof v === "object" && v !== null ? Object.fromEntries(Object.entries(v)) : {});

/** A mesh with one device whose ACL lets it reach every VM: each attaching VM needs a rule for it to be reachable. */
const meshWithDevice = async () => {
  const key = await h.addKey(TEAM, ALL_SCOPES);
  const created = await h.request("/v1/meshes", bearer(key), { method: "POST", body: {} });
  expect(created.status).toBe(201);
  const meshId = String(record(await created.json())["id"]);
  const install = await makeInstallKey();
  const enrolled = await h.request(`/v1/meshes/${meshId}/devices`, bearer(key), { method: "POST", body: await enrollBody(install, meshId, { name: "laptop", wgPublicKey: KEY }) });
  expect(enrolled.status).toBe(201);
  const acl = await h.request(`/v1/meshes/${meshId}/acl`, bearer(key), { method: "PUT", body: { expectedVersion: 0, rules: [{ src: ["device:*"], dst: ["vm:*"], allow: ["tcp:22"] }] } });
  expect(acl.status).toBe(200);
  return { key, meshId };
};

/** Whether the provider holds a rule to the VM: the apply that covers its attach has landed. */
const reachable = (upstreamId: string) => [...h.mesh.rules.values()].some((rule) => rule.destination["vmId"] === upstreamId);

/** Attaches `ATTACHES` VMs at once; each answer records its status, its time and whether its rule existed when it came. */
const attachAll = async (key: string, meshId: string, options: { readonly onAnswer?: (status: number) => void; readonly queued?: boolean } = {}) => {
  const vms = Array.from({ length: ATTACHES }, () => h.addVm(TEAM));
  const appliesBefore = h.mesh.storeCallCountOf("currentAcl");
  const membersBefore = h.mesh.storeCallCountOf("attachMember");
  h.mesh.delayStoreMethod("currentAcl", APPLY_MS);
  // queued: another writer holds the mesh until every attach has written its member row, so the first apply reads them all.
  const blocker = "an-earlier-writer";
  const lockKey = `mesh-writer:${meshId}`;
  if (options.queued === true) expect(await Effect.runPromise(limits.lock(TenantId.make(TEAM), lockKey, blocker, 60_000))).toBe(true);
  const started = Date.now();
  const answering = Promise.all(vms.map((vm) =>
    h.request(`/v1/meshes/${meshId}/vms/${vm.vmId}`, bearer(key), { method: "PUT" }).then((response) => {
      options.onAnswer?.(response.status);
      return { status: response.status, ms: Date.now() - started, covered: reachable(vm.upstreamId) };
    })));
  if (options.queued === true) {
    while (h.mesh.storeCallCountOf("attachMember") - membersBefore < ATTACHES) await new Promise((resolve) => setTimeout(resolve, 10));
    await new Promise((resolve) => setTimeout(resolve, 100));
    await Effect.runPromise(limits.unlock(TenantId.make(TEAM), lockKey, blocker));
  }
  const answers = await answering;
  h.mesh.delayStoreMethod("currentAcl", 0);
  // One ACL read per read-compile-apply (reconcileCurrent); an attach answered by another's apply reads none.
  const applies = h.mesh.storeCallCountOf("currentAcl") - appliesBefore;
  return { answers, applies };
};

describe("concurrent mesh attaches", () => {
  it("answer 10 attaches with at most 2 applies, each after an apply that covers it", async () => {
    const { key, meshId } = await meshWithDevice();
    const { answers, applies } = await attachAll(key, meshId);
    const times = answers.map((answer) => answer.ms).sort((a, b) => a - b);
    console.log(JSON.stringify({ event: "mesh_attach_coalesce", attaches: ATTACHES, applyMs: APPLY_MS, applies, answerMs: times }));
    expect(answers.map((answer) => answer.status)).toEqual(Array.from({ length: ATTACHES }, () => 200));
    expect(answers.every((answer) => answer.covered)).toBe(true);
    expect(applies).toBeLessThanOrEqual(2);
  }, 60_000);

  it("never answers an attach as covered by an apply that failed", async () => {
    const { key, meshId } = await meshWithDevice();
    // The first apply's rule creates are refused; the refusal ends with its own answer (a 503), after which the
    // provider takes creates again.
    h.mesh.failRuleCreates(500);
    // Queued behind an earlier writer, that first apply reads every attach's member row: each must still get an apply
    // that lands before it answers.
    const { answers, applies } = await attachAll(key, meshId, { queued: true, onAnswer: (status) => { if (status !== 200) h.mesh.failRuleCreates(null); } });
    console.log(JSON.stringify({ event: "mesh_attach_coalesce_failed_apply", applies, answers }));
    const failed = answers.filter((answer) => answer.status !== 200);
    expect(failed.length).toBeGreaterThanOrEqual(1);
    expect(failed.every((answer) => answer.status === 503)).toBe(true);
    // Every attach that answered 200 was reachable when it answered: none was let through by the failed apply.
    for (const answer of answers) if (answer.status === 200) expect(answer.covered).toBe(true);
  }, 60_000);
});

describe("the mesh_vm_attach line", () => {
  it("stamps the handler's entry before the caller gate, the rate limit and the mesh ownership read", async () => {
    const { key, meshId } = await meshWithDevice();
    const vm = h.addVm(TEAM);
    const lines: Array<Record<string, string>> = [];
    const spy = vi.spyOn(console, "error").mockImplementation((line: unknown) => {
      if (typeof line !== "string" || !line.startsWith("{")) return;
      const parsed = record(JSON.parse(line));
      if (parsed["event"] === "mesh_vm_attach") lines.push(Object.fromEntries(Object.entries(parsed).map(([k, v]) => [k, String(v)])));
    });
    const before = Date.now();
    const answer = await h.request(`/v1/meshes/${meshId}/vms/${vm.vmId}`, bearer(key), { method: "PUT" });
    const after = Date.now();
    spy.mockRestore();
    expect(answer.status).toBe(200);
    expect(lines).toHaveLength(1);
    const line = lines[0]!;
    // entered_at is the handler's first stamp: the pre-timer work (gate, rate limit, mesh ownership) is preMs, which
    // totalMs never counts; the audit write after the attach is auditMs, inside totalMs.
    const entered = Number(line["enteredAt"]);
    expect(entered).toBeGreaterThanOrEqual(before);
    expect(entered).toBeLessThanOrEqual(after);
    for (const field of ["preMs", "gateMs", "rateMs", "ownsMeshMs", "auditMs", "totalMs"]) expect(Number(line[field])).toBeGreaterThanOrEqual(0);
    // The apply's compile splits into its one read and the mesh's size (one VM, one device here).
    expect(Number(line["readMs"])).toBeLessThanOrEqual(Number(line["compileMs"]));
    expect(line).toMatchObject({ members: "1", devices: "1" });
    expect(Number(line["preMs"])).toBeGreaterThanOrEqual(Number(line["ownsMeshMs"]));
    expect(entered + Number(line["preMs"]) + Number(line["totalMs"])).toBeLessThanOrEqual(after);
    expect(Number(line["auditMs"])).toBeLessThanOrEqual(Number(line["totalMs"]));
  }, 60_000);

  // On a fake clock: the audit append advances it 40 ms and the attach 100 ms, so the line names exactly both.
  const auditing = (ms: number) => Layer.succeed(AuditStore, { append: () => TestClock.adjust(Duration.millis(ms)) });
  const entry: AuditEntry = { tenantId: TenantId.make(TEAM), actor: "key:test", ownerActor: null, action: "mesh.vm.attach", cmuxId: null, outcome: "ok", at: new Date(0) };
  const logged = async (attach: (begin: Effect.Effect<number>) => Effect.Effect<unknown, unknown, AuditStore>) => {
    const lines: Array<Record<string, unknown>> = [];
    const spy = vi.spyOn(console, "error").mockImplementation((line: unknown) => {
      if (typeof line === "string" && line.startsWith("{")) lines.push(record(JSON.parse(line)));
    });
    const phases: Record<string, string> = { preMs: "5" };
    await Effect.runPromise(timedAttach(phases, attach).pipe(Effect.either, Effect.provide(Layer.merge(auditing(40), TestContext.TestContext))));
    spy.mockRestore();
    return lines.filter((line) => line["event"] === "mesh_vm_attach");
  };
  const append = Effect.flatMap(AuditStore, (store) => store.append(entry));

  it("times the audit write as auditMs and counts it in totalMs", async () => {
    const lines = await logged((begin) => Effect.gen(function* () {
      yield* begin;
      yield* TestClock.adjust(Duration.millis(100));
      yield* append;
    }));
    expect(lines).toEqual([{ event: "mesh_vm_attach", preMs: "5", auditMs: "40", totalMs: "140" }]);
  });

  it("times a refused attach's audit write too, and logs nothing for one refused before it began", async () => {
    const refused = await logged((begin) => Effect.gen(function* () {
      yield* begin;
      yield* Effect.flatMap(append, () => Effect.fail("conflict"));
    }));
    expect(refused).toEqual([{ event: "mesh_vm_attach", preMs: "5", auditMs: "40", totalMs: "40" }]);
    expect(await logged(() => Effect.fail("gate"))).toEqual([]);
  });
});
