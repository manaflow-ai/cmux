import { afterEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schedule from "effect/Schedule";
import * as TestClock from "effect/TestClock";
import * as TestContext from "effect/TestContext";
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { guestVmKindCommand, scheduleGuestVmKindRecord } from "../services/vms/guestVmKind";
import type { VmGuestKind } from "../services/vms/vmKind";
import { VmProviderGateway, VmProviderGatewayLive, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type BeginBaseCreateResult, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { createVm, openBaseVm, resetBaseVm, restoreVm } from "../services/vms/workflows";
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

/** Runs the guest command against root as the provider exec would; `bin` goes first on PATH. */
async function runGuest(root: string, kind: VmGuestKind = "owner", bin?: string) {
  const env = bin ? { ...process.env, PATH: `${bin}:${process.env.PATH}` } : undefined;
  const result = await runChild("sh", ["-c", guestVmKindCommand(kind, kindDir(root))], { env });
  return { exitCode: result.status ?? 1, stdout: result.stdout, stderr: result.stderr };
}

/** A directory holding one executable `ln` with this body (a stand-in that misbehaves on cue). */
function fakeLn(root: string, body: string): string {
  const bin = path.join(root, "bin");
  mkdirSync(bin);
  writeFileSync(path.join(bin, "ln"), `#!/bin/sh\n${body}\n`);
  chmodSync(path.join(bin, "ln"), 0o755);
  return bin;
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

  test("keeps an existing record or a symlink", async () => {
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

  test("never writes into a directory that appears at the marker path after the check", async () => {
    const root = guestRoot();
    // The directory appears between the existence check and the link; then
    // the real ln runs (this stand-in's directory is first on PATH).
    const bin = fakeLn(root, `mkdir "$3"; PATH="\${PATH#*:}" exec ln "$@"`);
    expect(await runGuest(root, "owner", bin)).toEqual({ exitCode: 0, stdout: "kept\n", stderr: "" });
    expect(statSync(kindFile(root)).isDirectory()).toBe(true);
    expect(readdirSync(kindFile(root))).toEqual([]);
    expect(readdirSync(kindDir(root))).toEqual(["vm-kind"]);
  });

  test("removes its temporary file when killed, and sweeps one an earlier kill left", async () => {
    const root = guestRoot();
    const stale = path.join(kindDir(root), ".vm-kind.stale1");
    const fresh = path.join(kindDir(root), ".vm-kind.fresh1");
    writeFileSync(stale, "owner\n");
    writeFileSync(fresh, "owner\n");
    const old = new Date(Date.now() - 5 * 60_000);
    utimesSync(stale, old, old);
    // The provider's timeout kills the shell while ln runs.
    const bin = fakeLn(root, `kill -TERM $PPID; sleep 0.2; exit 1`);
    const killed = await runGuest(root, "owner", bin);
    expect(killed.exitCode).not.toBe(0);
    // The stale one is swept; a fresh one may be a live writer's (the image's sync) and stays.
    expect(readdirSync(kindDir(root)).sort()).toEqual([".vm-kind.fresh1"]);
    expect(cmuxVm(root)).toBe(false);
  });

  test("sweeps a stale temporary file even when the record already exists", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    const stale = path.join(kindDir(root), ".vm-kind.stale2");
    writeFileSync(stale, "owner\n");
    const old = new Date(Date.now() - 5 * 60_000);
    utimesSync(stale, old, old);
    expect((await runGuest(root)).stdout).toBe("kept\n");
    expect(readdirSync(kindDir(root))).toEqual(["vm-kind"]);
  });

  test("creates a missing /etc/cmux", async () => {
    const root = guestRoot();
    rmSync(kindDir(root), { recursive: true });
    expect((await runGuest(root)).stdout).toBe("written\n");
    expect(statSync(kindDir(root)).mode & 0o777).toBe(0o755);
    expect(cmuxVm(root)).toBe(true);
  });
});

// The workflows with a fake provider whose guest is a temporary root.

const NOW = new Date("2026-10-27T00:00:00.000Z");
const PROVIDER_VM_ID = "provider-vm-own";

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

function baseCreate(vm: CloudVmRow): BeginBaseCreateResult {
  return {
    kind: "create",
    vm,
    base: {
      id: "base-own", scopeType: "team", scopeId: vm.ownerTeamId, name: "base",
      activeGeneration: 1, activeVmId: null, activeProvider: null, activeProviderVmId: null,
      state: "provisioning", createdByUserId: vm.userId, lastOpenedByUserId: vm.userId,
      createdAt: NOW, updatedAt: NOW,
    },
    generation: {
      id: "generation-own", baseId: "base-own", generation: 1, vmId: vm.id,
      provider: "freestyle", providerVmId: null, state: "provisioning",
      createdByUserId: vm.userId, retainedAt: null, deletedAt: null, createdAt: NOW, updatedAt: NOW,
    },
    previousGeneration: null,
    previousVm: null,
  } as BeginBaseCreateResult;
}

function harness(input: { vm?: CloudVmRow; root: string; failExecs?: number; onFailedExec?: () => void; neverAnswer?: boolean }) {
  const vm = input.vm ?? row();
  const execs: Exec[] = [];
  let failures = input.failExecs ?? 0;
  // What the database holds now; a test deletes or rebinds the machine through it.
  const state: { live: CloudVmRow | null } = { live: null };
  const running = (update: { providerVmId: string }) => {
    state.live = { ...vm, status: "running", providerVmId: update.providerVmId };
    return state.live;
  };
  const repo = {
    beginCreate: () => Effect.succeed({ inserted: true, vm }),
    beginBaseOpen: () => Effect.succeed(baseCreate(vm)),
    beginBaseReset: () => Effect.succeed(baseCreate(vm)),
    hasOwnedSnapshot: () => Effect.succeed(true),
    ownedSnapshotResourceReservation: () => Effect.succeed({ vcpus: 4, memoryMb: 8192, diskMb: 32768 }),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
    markCreateFailed: () => Effect.succeed(true),
    markBaseCreateFailed: () => Effect.succeed(true),
    markCreateRunning: (update: { providerVmId: string }) => Effect.sync(() => running(update)),
    markBaseCreateRunning: (update: { providerVmId: string }) => Effect.sync(() => running(update)),
    findUserVm: (lookup: { userId: string; billingTeamId?: string | null; providerVmId: string }) => Effect.sync(() => {
      const live = state.live;
      return live && live.userId === lookup.userId && live.ownerTeamId === lookup.billingTeamId && live.providerVmId === lookup.providerVmId
        && live.status !== "destroyed" ? live : null;
    }),
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
      const kind = (["owner", "team"] as const).find((k) => command === guestVmKindCommand(k));
      // Only a marker command reaches the fake guest; the prompt push answers 0.
      if (!kind) return Effect.succeed({ exitCode: 0, stdout: "", stderr: "" });
      if (input.neverAnswer) return Effect.never;
      if (failures > 0) {
        failures -= 1;
        input.onFailedExec?.();
        return Effect.fail(new Error("the machine's exec did not answer"));
      }
      return Effect.promise(() => runGuest(input.root, kind));
    },
    create: () => Effect.succeed({ provider: vm.provider, providerVmId: PROVIDER_VM_ID, status: "running" as const, image: "snapshot-test", createdAt: NOW.getTime() }),
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
  const deferAfterResponse = (work: Effect.Effect<void>) => { deferred.push(work); };
  const common = {
    userId: vm.userId,
    billingCustomerType: "user" as const,
    billingTeamId: vm.billingTeamId ?? vm.ownerTeamId,
    billingPlanId: "pro",
    maxActiveVms: null,
    provider: vm.provider,
    image: "snapshot-test",
    deferAfterResponse,
  };
  const create = () => Effect.runPromise(createVm(common).pipe(Effect.provide(layer)));
  const openBase = (operation: typeof openBaseVm | typeof resetBaseVm) => Effect.runPromise(operation(common).pipe(Effect.provide(layer)));
  const restore = () => Effect.runPromise(restoreVm({ ...common, snapshotId: "snapshot-own" }).pipe(Effect.provide(layer)));
  const runDeferred = async () => { for (const work of deferred.splice(0)) await Effect.runPromise(work); };
  /** Runs the after-response work on a test clock, so the real retry schedule and budget pass at once. */
  const runDeferredOnTestClock = async () => {
    for (const work of deferred.splice(0)) {
      await Effect.runPromise(Effect.gen(function* () {
        const fiber = yield* Effect.fork(work);
        for (let i = 0; i < 100 && Option.isNone(yield* fiber.poll); i += 1) yield* TestClock.adjust("5 seconds");
        yield* Fiber.join(fiber);
      }).pipe(Effect.provide(TestContext.TestContext)));
    }
  };
  const markerExecs = () => execs.filter((exec) => exec.command === guestVmKindCommand("owner") || exec.command === guestVmKindCommand("team"));
  return { repo, providers, state, execs, deferred, markerExecs, create, openBase, restore, runDeferred, runDeferredOnTestClock };
}

describe("createVm records the machine's vm-kind", () => {
  test("a fresh personal create reads cmuxVm true once the after-response work ran", async () => {
    const root = guestRoot();
    const h = harness({ root });
    const created = await h.create();
    expect(created.providerVmId).toBe(PROVIDER_VM_ID);
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

  test("an exec that keeps failing never fails the create, and its work ends on the real schedule", async () => {
    const root = guestRoot();
    const h = harness({ root, failExecs: Number.MAX_SAFE_INTEGER });
    const created = await h.create();
    expect(created.providerVmId).toBe(PROVIDER_VM_ID);
    expect(h.deferred).toHaveLength(3);
    // The failed writes run to their end, and the work still succeeds.
    await h.runDeferredOnTestClock();
    expect(h.markerExecs()).toHaveLength(13);
    expect(cmuxVm(root)).toBe(false);
  });

  test("an exec that never answers ends within the budget", async () => {
    const root = guestRoot();
    const h = harness({ root, neverAnswer: true });
    await h.create();
    await h.runDeferredOnTestClock();
    expect(h.markerExecs()).toHaveLength(1);
  });
});

describe("Base open and reset record the machine's vm-kind after the response", () => {
  for (const [name, operation] of [["open", openBaseVm], ["reset", resetBaseVm]] as const) {
    test(name, async () => {
      const root = guestRoot();
      const h = harness({ root });
      const opened = await h.openBase(operation);
      expect(opened.providerVmId).toBe(PROVIDER_VM_ID);
      expect(h.markerExecs()).toEqual([]);
      expect(h.deferred).toHaveLength(1);
      await h.runDeferred();
      expect(h.markerExecs()).toEqual([{ command: guestVmKindCommand("owner"), asRoot: true }]);
      expect(cmuxVm(root)).toBe(true);
    });
  }
});

test("a restore records the machine's vm-kind after the response", async () => {
  const root = guestRoot();
  const h = harness({ root });
  const restored = await h.restore();
  expect(restored.providerVmId).toBe(PROVIDER_VM_ID);
  expect(h.markerExecs()).toEqual([]);
  await h.runDeferred();
  expect(h.markerExecs()).toEqual([{ command: guestVmKindCommand("owner"), asRoot: true }]);
  expect(cmuxVm(root)).toBe(true);
});

describe("scheduleGuestVmKindRecord", () => {
  const running = row({ status: "running", providerVmId: PROVIDER_VM_ID });

  /** Starts the work on the harness's own repo and provider, with immediate retries. */
  async function record(h: ReturnType<typeof harness>, retries = 5) {
    h.state.live = running;
    const deferred: Array<Effect.Effect<void>> = [];
    await Effect.runPromise(scheduleGuestVmKindRecord(h.repo, h.providers, running, (work) => { deferred.push(work); }, Schedule.recurs(retries)));
    expect(deferred).toHaveLength(1);
    // The work itself never fails.
    await Effect.runPromise(deferred[0]!);
  }

  test("retries until the machine's exec answers", async () => {
    const root = guestRoot();
    const h = harness({ root, failExecs: 2 });
    await record(h);
    expect(h.markerExecs()).toHaveLength(3);
    expect(cmuxVm(root)).toBe(true);
  });

  test("retries a bounded number of times, then logs and succeeds", async () => {
    const root = guestRoot();
    const h = harness({ root, failExecs: Number.MAX_SAFE_INTEGER });
    await record(h, 3);
    expect(h.markerExecs()).toHaveLength(4);
    expect(cmuxVm(root)).toBe(false);
  });

  test("retries a non-zero exit like a silent exec", async () => {
    const h = harness({ root: guestRoot() });
    let calls = 0;
    const providers = {
      exec: () => Effect.sync(() => {
        calls += 1;
        return calls < 3 ? { exitCode: 124, stdout: "", stderr: "" } : { exitCode: 0, stdout: "written\n", stderr: "" };
      }),
    } as unknown as VmProviderGatewayShape;
    h.state.live = running;
    const deferred: Array<Effect.Effect<void>> = [];
    await Effect.runPromise(scheduleGuestVmKindRecord(h.repo, providers, running, (work) => { deferred.push(work); }, Schedule.recurs(5)));
    await Effect.runPromise(deferred[0]!);
    expect(calls).toBe(3);
  });

  test("stops with no exec when the machine was deleted before the first try", async () => {
    const h = harness({ root: guestRoot() });
    h.state.live = null;
    const deferred: Array<Effect.Effect<void>> = [];
    await Effect.runPromise(scheduleGuestVmKindRecord(h.repo, h.providers, running, (work) => { deferred.push(work); }, Schedule.recurs(5)));
    await Effect.runPromise(deferred[0]!);
    expect(h.markerExecs()).toEqual([]);
  });

  test("stops retrying once the machine is deleted during the backoff", async () => {
    const root = guestRoot();
    const h = harness({ root, failExecs: Number.MAX_SAFE_INTEGER, onFailedExec: () => { h.state.live = { ...running, status: "destroyed" }; } });
    await record(h);
    expect(h.markerExecs()).toHaveLength(1);
  });

  test("never writes to a provider id that now belongs to another machine or owner", async () => {
    for (const rebound of [
      { ...running, id: "00000000-0000-4000-8000-0000000004b2" },
      { ...running, ownerTeamId: "team-other", billingTeamId: "team-other" },
      { ...running, status: "paused" as const },
    ]) {
      const root = guestRoot();
      const h = harness({ root, failExecs: 1, onFailedExec: () => { h.state.live = rebound; } });
      await record(h);
      // The first try ran; the retry found another machine and stopped.
      expect(h.markerExecs()).toHaveLength(1);
      expect(cmuxVm(root)).toBe(false);
    }
  });
});

describe("an exec with cancelOnInterrupt", () => {
  /** A Freestyle API that never answers and reports when a request was aborted. */
  async function withHangingFreestyle(run: (aborted: Promise<boolean>) => Promise<void>) {
    let markAborted!: () => void;
    const abortedOnce = new Promise<void>((resolve) => { markAborted = resolve; });
    let requests = 0;
    // Never answers; the client going away aborts the request (and closes the response).
    const server = createServer((request, response) => {
      requests += 1;
      request.on("aborted", () => markAborted());
      response.on("close", () => markAborted());
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    const port = typeof address === "object" && address ? address.port : 0;
    const saved = { url: process.env.FREESTYLE_API_URL, key: process.env.FREESTYLE_API_KEY };
    process.env.FREESTYLE_API_URL = `http://127.0.0.1:${port}`;
    process.env.FREESTYLE_API_KEY = "test-key";
    const aborted = Promise.race([
      abortedOnce.then(() => true),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 1_500)),
    ]);
    try {
      await run(aborted);
      expect(requests).toBeGreaterThan(0);
    } finally {
      for (const [name, value] of [["FREESTYLE_API_URL", saved.url], ["FREESTYLE_API_KEY", saved.key]] as const) {
        if (value === undefined) delete process.env[name];
        else process.env[name] = value;
      }
      server.closeAllConnections();
      server.close();
    }
  }

  const exec = (cancelOnInterrupt: boolean) => Effect.flatMap(VmProviderGateway, (providers) =>
    providers.exec("freestyle", "vm-hanging", "true", { timeoutMs: 30_000, asRoot: true, cancelOnInterrupt }),
  ).pipe(Effect.timeout("200 millis"), Effect.exit, Effect.provide(VmProviderGatewayLive));

  test("a timeout ends the Freestyle request itself, not only the wait", async () => {
    await withHangingFreestyle(async (aborted) => {
      const exit = await Effect.runPromise(exec(true));
      expect(exit._tag).toBe("Failure");
      expect(await aborted).toBe(true);
    });
  });

  test("without it, a timed-out exec's request runs on", async () => {
    await withHangingFreestyle(async (aborted) => {
      const exit = await Effect.runPromise(exec(false));
      expect(exit._tag).toBe("Failure");
      expect(await aborted).toBe(false);
    });
  });
});
