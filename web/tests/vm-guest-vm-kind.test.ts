import { afterEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schedule from "effect/Schedule";
import { lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { guestVmKindCommand, scheduleGuestVmKindRecord } from "../services/vms/guestVmKind";
import type { VmGuestKind } from "../services/vms/vmKind";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { createVm } from "../services/vms/workflows";
import { runChild } from "./helpers/run-child";

// A machine New Machine makes for its owner must read `owner` in
// /etc/cmux/vm-kind, or acpmux's `host vm-host` reads cmuxVm:false and
// vmHost stays off (cmux-tui acpmux hub/vm_host.rs). Its devbox image may
// have no guest writer, so the create writes it over the provider exec.

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

/** A fake guest filesystem root, with /etc/cmux in it. */
function guestRoot(): string {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-vm-kind-"));
  roots.push(root);
  mkdirSync(path.join(root, "etc/cmux"), { recursive: true, mode: 0o755 });
  return root;
}

const kindDir = (root: string) => path.join(root, "etc/cmux");
const kindFile = (root: string) => path.join(kindDir(root), "vm-kind");

/** acpmux hub/vm_host.rs `cmux_vm_at`: no team files root, and a vm-kind reading `owner`. */
function cmuxVm(root: string): boolean {
  try {
    lstatSync(path.join(root, "srv/team"));
    return false;
  } catch {}
  try {
    return readFileSync(kindFile(root), "utf8").trim() === "owner";
  } catch {
    return false;
  }
}

/** Runs the guest command against root as the provider exec would. */
async function runGuest(root: string, kind: VmGuestKind = "owner") {
  const result = await runChild("sh", ["-c", guestVmKindCommand(kind, kindDir(root))]);
  return { exitCode: result.status ?? 1, stdout: result.stdout, stderr: result.stderr };
}

describe("guest vm-kind command", () => {
  test("writes owner, root-readable 0644, where none exists", async () => {
    const root = guestRoot();
    expect(cmuxVm(root)).toBe(false);
    const result = await runGuest(root);
    expect(result).toEqual({ exitCode: 0, stdout: "written\n", stderr: "" });
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
    expect(statSync(kindFile(root)).mode & 0o777).toBe(0o644);
    expect(cmuxVm(root)).toBe(true);
  });

  test("writes team where none exists, which acpmux reads as not a cmux VM", async () => {
    const root = guestRoot();
    expect((await runGuest(root, "team")).stdout).toBe("written\n");
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    expect(cmuxVm(root)).toBe(false);
  });

  test("takes only owner or team", () => {
    expect(() => guestVmKindCommand("x'; rm -rf /; '" as VmGuestKind)).toThrow();
  });

  test("is idempotent and leaves no temporary file", async () => {
    const root = guestRoot();
    await runGuest(root);
    expect(await runGuest(root)).toEqual({ exitCode: 0, stdout: "kept\n", stderr: "" });
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
    expect(readdirSync(kindDir(root))).toEqual(["vm-kind"]);
  });

  test("never overwrites an existing marker or a symlink", async () => {
    for (const [kind, plant] of [
      ["owner", (file: string) => writeFileSync(file, "team\n")],
      ["team", (file: string) => writeFileSync(file, "owner\n")],
      ["owner", (file: string) => writeFileSync(file, "")],
      ["owner", (file: string) => symlinkSync("/nonexistent/vm-kind", file)],
    ] as const) {
      const root = guestRoot();
      plant(kindFile(root));
      const before = lstatSync(kindFile(root));
      const contents = before.isSymbolicLink() ? null : readFileSync(kindFile(root), "utf8");
      expect(await runGuest(root, kind)).toEqual({ exitCode: 0, stdout: "kept\n", stderr: "" });
      const after = lstatSync(kindFile(root));
      expect([after.ino, after.isSymbolicLink()]).toEqual([before.ino, before.isSymbolicLink()]);
      expect(after.isSymbolicLink() ? null : readFileSync(kindFile(root), "utf8")).toBe(contents);
    }
  });

  test("creates a missing /etc/cmux", async () => {
    const root = guestRoot();
    rmSync(kindDir(root), { recursive: true });
    expect((await runGuest(root)).stdout).toBe("written\n");
    expect(statSync(kindDir(root)).mode & 0o777).toBe(0o755);
    expect(cmuxVm(root)).toBe(true);
  });
});

// createVm with a fake provider whose guest is a temporary root.

const NOW = new Date("2026-10-27T00:00:00.000Z");

function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-0000000004b1",
    userId: "user-own",
    billingTeamId: "user-own",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: null,
    displayName: null,
    slug: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "provisioning",
    idempotencyKey: null,
    createdAt: NOW,
    updatedAt: NOW,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    networkPolicy: null,
    networkPolicyStatus: null,
    agentUpdates: null,
    // The synthetic personal team: the creator's own user id.
    ownerTeamId: "user-own",
    coderouterPoolId: null,
    ...overrides,
  };
}

type Exec = { command: string; asRoot?: boolean };

function harness(input: { vm?: CloudVmRow; root: string; failExecs?: number }) {
  const vm = input.vm ?? row();
  const execs: Exec[] = [];
  let failures = input.failExecs ?? 0;
  const repo = {
    beginCreate: () => Effect.succeed({ inserted: true, vm }),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
    markCreateFailed: () => Effect.succeed(true),
    markCreateRunning: (update: { providerVmId: string; image: string }) =>
      Effect.succeed({ ...vm, status: "running", providerVmId: update.providerVmId, imageId: update.image }),
    activeLimitCandidates: () => Effect.succeed([]),
    findNetwork: () => Effect.succeed({
      id: "00000000-0000-4000-8000-00000000c10e", userId: vm.userId, provider: vm.provider, providerNetworkId: "network-own",
      slug: "own", cidr: null, cidrV6: null, createdAt: NOW, updatedAt: NOW,
    }),
    upsertNetwork: () => Effect.die("the owner network already exists"),
  } as unknown as VmRepositoryShape;
  const providers = {
    exec: (_provider: string, _vmId: string, command: string, options?: { readonly asRoot?: boolean }) => {
      execs.push({ command, asRoot: options?.asRoot });
      if (failures > 0) {
        failures -= 1;
        return Effect.fail(new Error("the machine's exec did not answer"));
      }
      // Only a marker command reaches the fake guest; the prompt push answers 0.
      const kind = (["owner", "team"] as const).find((k) => command === guestVmKindCommand(k));
      return kind ? Effect.promise(() => runGuest(input.root, kind)) : Effect.succeed({ exitCode: 0, stdout: "", stderr: "" });
    },
    create: () => Effect.succeed({ provider: vm.provider, providerVmId: "provider-vm-own", status: "running" as const, image: "snapshot-test", createdAt: NOW.getTime() }),
    destroy: () => Effect.void,
    supportsPrivateNetworking: () => true,
    ensureNetwork: () => Effect.die("the owner network already exists"),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  const deferred: Array<Effect.Effect<void>> = [];
  const create = () => Effect.runPromise(createVm({
    userId: vm.userId,
    billingCustomerType: "user",
    billingTeamId: vm.billingTeamId ?? vm.ownerTeamId,
    billingPlanId: "pro",
    maxActiveVms: null,
    provider: vm.provider,
    image: "snapshot-test",
    deferAfterResponse: (work) => { deferred.push(work); },
  }).pipe(Effect.provide(layer)));
  const runDeferred = async () => { for (const work of deferred.splice(0)) await Effect.runPromise(work); };
  const markerExecs = () => execs.filter((exec) => exec.command === guestVmKindCommand("owner") || exec.command === guestVmKindCommand("team"));
  return { providers, execs, markerExecs, create, runDeferred };
}

describe("createVm records the machine's vm-kind", () => {
  test("a fresh personal create reads cmuxVm true once the after-response work ran", async () => {
    const root = guestRoot();
    const h = harness({ root });
    const created = await h.create();
    expect(created.providerVmId).toBe("provider-vm-own");
    // Nothing ran in the guest before the response: still cmuxVm false.
    expect(h.execs).toEqual([]);
    expect(cmuxVm(root)).toBe(false);
    await h.runDeferred();
    expect(h.markerExecs()).toEqual([{ command: guestVmKindCommand("owner"), asRoot: true }]);
    expect(cmuxVm(root)).toBe(true);
  });

  test("a team machine records team, so vmHost stays off", async () => {
    const root = guestRoot();
    const h = harness({ root, vm: row({ billingTeamId: "team-shared", ownerTeamId: "team-shared" }) });
    await h.create();
    await h.runDeferred();
    expect(h.markerExecs()).toEqual([{ command: guestVmKindCommand("team"), asRoot: true }]);
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    expect(cmuxVm(root)).toBe(false);
  });

  test("a row with no billing owner records nothing", async () => {
    const root = guestRoot();
    const h = harness({ root, vm: row({ ownerTeamId: " " }) });
    await h.create();
    await h.runDeferred();
    expect(h.markerExecs()).toEqual([]);
  });

  test("a personal machine whose guest already reads team stays team", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "team\n");
    const h = harness({ root });
    await h.create();
    await h.runDeferred();
    expect(h.markerExecs()).toHaveLength(1);
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    expect(cmuxVm(root)).toBe(false);
  });

  test("a GCP machine gets no marker from the create", async () => {
    const root = guestRoot();
    const h = harness({ root, vm: row({ provider: "gcp" }) });
    await h.create();
    await h.runDeferred();
    expect(h.markerExecs()).toEqual([]);
  });

  test("a failing exec never fails the create", async () => {
    const root = guestRoot();
    const h = harness({ root, failExecs: Number.MAX_SAFE_INTEGER });
    const created = await h.create();
    expect(created.providerVmId).toBe("provider-vm-own");
    expect(h.execs).toEqual([]);
  });
});

describe("scheduleGuestVmKindRecord retries", () => {
  const running = row({ status: "running", providerVmId: "provider-vm-own" });

  test("until the machine's exec answers", async () => {
    const root = guestRoot();
    const h = harness({ root, failExecs: 2 });
    const deferred: Array<Effect.Effect<void>> = [];
    await Effect.runPromise(scheduleGuestVmKindRecord(h.providers, running, (work) => { deferred.push(work); }, Schedule.recurs(5)));
    await Effect.runPromise(deferred[0]!);
    expect(h.markerExecs()).toHaveLength(3);
    expect(cmuxVm(root)).toBe(true);
  });

  test("a bounded number of times, then logs and succeeds", async () => {
    const root = guestRoot();
    const h = harness({ root, failExecs: Number.MAX_SAFE_INTEGER });
    const deferred: Array<Effect.Effect<void>> = [];
    await Effect.runPromise(scheduleGuestVmKindRecord(h.providers, running, (work) => { deferred.push(work); }, Schedule.recurs(3)));
    expect(deferred).toHaveLength(1);
    // The deferred work itself never fails.
    await Effect.runPromise(deferred[0]!);
    expect(h.markerExecs()).toHaveLength(4);
    expect(cmuxVm(root)).toBe(false);
  });

  test("a non-zero exit is retried like a silent exec", async () => {
    const running2 = row({ status: "running", providerVmId: "provider-vm-own" });
    let calls = 0;
    const providers = {
      exec: () => Effect.sync(() => {
        calls += 1;
        return calls < 3 ? { exitCode: 124, stdout: "", stderr: "" } : { exitCode: 0, stdout: "written\n", stderr: "" };
      }),
    } as unknown as VmProviderGatewayShape;
    const deferred: Array<Effect.Effect<void>> = [];
    await Effect.runPromise(scheduleGuestVmKindRecord(providers, running2, (work) => { deferred.push(work); }, Schedule.recurs(5)));
    await Effect.runPromise(deferred[0]!);
    expect(calls).toBe(3);
  });
});
