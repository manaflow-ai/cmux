import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmNotFoundError } from "../services/vms/errors";
import { MACHINE_HYGIENE_HEREDOC, machineHygieneCommand } from "../services/vms/hygiene/command";
import { MACHINE_HYGIENE_SCRIPT } from "../services/vms/hygiene/script.generated";
import {
  parseMachineHygieneReport,
  parseMachineHygieneRequest,
  runMachineHygiene,
  type MachineHygieneReport,
} from "../services/vms/hygiene/workflow";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { runChild } from "./helpers/run-child";

// POST /api/vm/[id]/hygiene runs cmux-machine-hygiene on one of the caller's
// own machines through exec. These tests pin that a call without apply
// deletes nothing (by running the exact command the route sends against a
// throwaway machine), that apply must be exactly `true`, that only the
// owner may run it, and that a paused machine is never woken.

const SCRIPT = path.join(import.meta.dirname, "../services/vms/hygiene/cmux-machine-hygiene");
const DAY_S = 24 * 60 * 60;

setDefaultTimeout(30_000);

const fixtures: string[] = [];
afterEach(() => {
  for (const root of fixtures.splice(0)) rmSync(root, { recursive: true, force: true });
});

function write(file: string, body = "x") {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, body);
}

function age(target: string, days: number) {
  const when = Date.now() / 1000 - days * DAY_S;
  const visit = (entry: string) => {
    if (statSync(entry).isDirectory()) for (const child of readdirSync(entry)) visit(path.join(entry, child));
    utimesSync(entry, when, when);
  };
  visit(target);
}

/** Every file and directory under a root, for before/after comparison. */
function tree(root: string): string[] {
  const out: string[] = [];
  const visit = (dir: string) => {
    for (const name of readdirSync(dir).sort()) {
      const entry = path.join(dir, name);
      out.push(path.relative(root, entry));
      if (statSync(entry).isDirectory()) visit(entry);
    }
  };
  visit(root);
  return out;
}

/** A throwaway machine full of things the script would reclaim. */
function machine() {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-hygiene-route-"));
  fixtures.push(root);
  const home = path.join(root, "home");
  const tmp = path.join(root, "tmp");
  const bin = path.join(root, "bin");
  const code = path.join(home, "code");
  for (const dir of [home, tmp, bin, code]) mkdirSync(dir, { recursive: true });
  write(path.join(bin, "mount"), "#!/bin/sh\necho '/dev/root on / type ext4 (rw)'\n");
  chmodSync(path.join(bin, "mount"), 0o755);
  // The real Docker must never run from a test: this one records and fails.
  write(path.join(bin, "docker"), `#!/bin/sh\necho "$*" >> ${JSON.stringify(path.join(root, "docker.calls"))}\nexit 99\n`);
  chmodSync(path.join(bin, "docker"), 0o755);
  write(path.join(code, "app", "package.json"), "{}");
  write(path.join(code, "app", "src", "main.ts"), "export {};");
  write(path.join(code, "app", "node_modules", "pkg", "index.js"), "1");
  write(path.join(home, ".claude", "debug", "old.txt"), "old log");
  write(path.join(tmp, "old-build.log"), "old");
  age(path.join(code, "app"), 30);
  age(path.join(home, ".claude", "debug", "old.txt"), 30);
  age(path.join(tmp, "old-build.log"), 30);
  return { root, home, tmp, bin, code };
}

async function runCommandLocally(m: ReturnType<typeof machine>, apply: boolean) {
  const command = machineHygieneCommand({ apply, home: m.home, roots: [m.code], tmpDir: m.tmp });
  const result = await runChild("sh", ["-c", command], {
    env: {
      PATH: `${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
      HOME: m.home,
      TMPDIR: m.tmp,
      CMUX_HYGIENE_SANDBOX: m.root,
      CMUX_HYGIENE_SANDBOX_APPLY: apply ? "1" : undefined,
    },
  });
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  expect(existsSync(path.join(m.root, "docker.calls"))).toBe(false);
  return JSON.parse(result.stdout) as MachineHygieneReport;
}

describe("machine hygiene command", () => {
  test("embeds the script exactly as the bash source", () => {
    expect(MACHINE_HYGIENE_SCRIPT).toBe(readFileSync(SCRIPT, "utf8"));
  });

  test("fits the provider's exec limit and never collides with its heredoc delimiter", () => {
    expect(MACHINE_HYGIENE_SCRIPT.split("\n")).not.toContain(MACHINE_HYGIENE_HEREDOC);
    expect(Buffer.byteLength(machineHygieneCommand({ apply: true }), "utf8")).toBeLessThan(60 * 1024);
  });

  test("passes --apply only when asked", () => {
    const lastLine = (apply: boolean) => machineHygieneCommand({ apply }).split("\n").pop() ?? "";
    expect(lastLine(false)).not.toContain("--apply");
    expect(lastLine(false)).toContain('--home "$cmux_hygiene_home" --root "$cmux_hygiene_home"');
    expect(lastLine(true).endsWith(" --apply")).toBe(true);
  });

  test("the command a call without apply sends deletes nothing", async () => {
    const m = machine();
    const before = tree(m.root);
    const report = await runCommandLocally(m, false);
    expect(report.mode).toBe("dry-run");
    expect(report.items.filter((item) => item.action === "would-delete").map((item) => item.path).sort()).toEqual(
      [
        path.join(m.code, "app", "node_modules"),
        path.join(m.home, ".claude", "debug", "old.txt"),
        path.join(m.tmp, "old-build.log"),
      ].sort(),
    );
    expect(report.items.some((item) => item.action === "deleted")).toBe(false);
    expect(tree(m.root)).toEqual(before);
  });

  test("the same command with apply does delete, so the dry-run proof is not vacuous", async () => {
    const m = machine();
    const report = await runCommandLocally(m, true);
    expect(report.mode).toBe("apply");
    expect(tree(m.root)).not.toContain(path.join("home", "code", "app", "node_modules"));
    expect(tree(m.root)).toContain(path.join("home", "code", "app", "src", "main.ts"));
  });
});

describe("machine hygiene request and report", () => {
  test("apply is false unless the body says exactly true", () => {
    expect(parseMachineHygieneRequest(undefined)).toEqual({ apply: false });
    expect(parseMachineHygieneRequest({})).toEqual({ apply: false });
    expect(parseMachineHygieneRequest({ apply: false })).toEqual({ apply: false });
    expect(parseMachineHygieneRequest({ apply: true })).toEqual({ apply: true });
    for (const bad of [{ apply: "true" }, { apply: 1 }, { apply: null }, [], "apply"]) {
      expect(parseMachineHygieneRequest(bad)).toBeNull();
    }
  });

  test("a report is accepted only in the requested mode, and a dry-run never carries deletions", () => {
    const report = (mode: string, action: string) =>
      JSON.stringify({
        version: 1,
        mode,
        home: "/home/cmux",
        diskUsedPctBefore: 50,
        diskUsedPctAfter: 50,
        reclaimableKb: 4,
        items: [{ category: "temp-files", path: "/tmp/x", kb: 4, action }],
      });
    expect(parseMachineHygieneReport(report("dry-run", "would-delete"), "dry-run")?.mode).toBe("dry-run");
    expect(parseMachineHygieneReport(report("apply", "deleted"), "apply")?.mode).toBe("apply");
    expect(parseMachineHygieneReport(report("apply", "deleted"), "dry-run")).toBeNull();
    expect(parseMachineHygieneReport(report("dry-run", "deleted"), "dry-run")).toBeNull();
    expect(parseMachineHygieneReport("not json", "dry-run")).toBeNull();
  });
});

describe("runMachineHygiene", () => {
  const OWNER = "user-owner";
  const TEAM = "team-shared";
  const dryRunStdout = JSON.stringify({
    version: 1, mode: "dry-run", home: "/home/cmux", diskUsedPctBefore: 40, diskUsedPctAfter: 40, reclaimableKb: 0, items: [],
  });
  const applyStdout = dryRunStdout.replace('"dry-run"', '"apply"');

  function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
    const now = new Date();
    return {
      id: "00000000-0000-4000-8000-0000000c1ea0", userId: OWNER, billingTeamId: TEAM, billingPlanId: "pro",
      provider: "freestyle", providerVmId: "vm-clean", displayName: null, slug: null, imageId: "snapshot-test",
      imageVersion: null, status: "running", idempotencyKey: null, createdAt: now, updatedAt: now, destroyedAt: null,
      failureCode: null, failureMessage: null, providerMetadata: {}, networkPolicy: null, networkPolicyStatus: null,
      agentUpdates: null, ownerTeamId: TEAM, coderouterPoolId: null, ...overrides,
    };
  }

  function harness(vm: CloudVmRow, options: { live?: "running" | "paused"; stdout?: string } = {}) {
    const commands: string[] = [];
    const repo: Partial<VmRepositoryShape> = { findUserVm: () => Effect.succeed(vm) };
    const providers: Partial<VmProviderGatewayShape> = {
      getStatus: () => Effect.succeed(options.live ?? "running"),
      exec: (_provider, _id, command) => Effect.sync(() => {
        commands.push(command);
        return { exitCode: 0, stdout: options.stdout ?? dryRunStdout, stderr: "" };
      }),
    };
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo as VmRepositoryShape),
      Layer.succeed(VmProviderGateway, providers as VmProviderGatewayShape),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );
    const run = (caller: { userId: string; apply: boolean }) =>
      Effect.runPromise(Effect.either(runMachineHygiene({
        userId: caller.userId, billingTeamId: TEAM, teamIds: [TEAM], providerVmId: "vm-clean", apply: caller.apply,
      })).pipe(Effect.provide(layer)));
    return { run, commands };
  }

  const lastLine = (command: string) => command.split("\n").pop() ?? "";

  test("the owner's call without apply sends a dry-run and returns its report", async () => {
    const h = harness(row());
    const result = await h.run({ userId: OWNER, apply: false });
    expect(result._tag === "Right" && result.right.kind).toBe("report");
    expect(h.commands).toHaveLength(1);
    expect(lastLine(h.commands[0]!)).not.toContain("--apply");
  });

  test("apply sends --apply, and a report in the wrong mode is a failure", async () => {
    const applied = harness(row(), { stdout: applyStdout });
    const ok = await applied.run({ userId: OWNER, apply: true });
    expect(ok._tag === "Right" && ok.right.kind).toBe("report");
    expect(lastLine(applied.commands[0]!).endsWith(" --apply")).toBe(true);
    const mismatched = harness(row(), { stdout: dryRunStdout });
    const failed = await mismatched.run({ userId: OWNER, apply: true });
    expect(failed._tag === "Right" && failed.right.kind).toBe("failed");
  });

  test("a teammate with access to the machine cannot run it", async () => {
    const h = harness(row());
    const result = await h.run({ userId: "user-teammate", apply: false });
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") expect(result.left).toBeInstanceOf(VmNotFoundError);
    expect(h.commands).toEqual([]);
  });

  test("another apply run on the machine answers busy", async () => {
    const commands: string[] = [];
    const vm = row();
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, { findUserVm: () => Effect.succeed(vm) } as unknown as VmRepositoryShape),
      Layer.succeed(VmProviderGateway, {
        getStatus: () => Effect.succeed("running" as const),
        exec: (_p: string, _i: string, command: string) => Effect.sync(() => {
          commands.push(command);
          return { exitCode: 4, stdout: "", stderr: "another cmux-machine-hygiene --apply is running (pid 7)\n" };
        }),
      } as unknown as VmProviderGatewayShape),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );
    const result = await Effect.runPromise(Effect.either(runMachineHygiene({
      userId: OWNER, billingTeamId: TEAM, teamIds: [TEAM], providerVmId: "vm-clean", apply: true,
    })).pipe(Effect.provide(layer)));
    expect(result._tag === "Right" && result.right.kind).toBe("busy");
  });

  test("never wakes a paused machine", async () => {
    for (const h of [harness(row({ status: "paused" })), harness(row(), { live: "paused" })]) {
      const result = await h.run({ userId: OWNER, apply: true });
      expect(result._tag === "Right" && result.right.kind).toBe("not-running");
      expect(h.commands).toEqual([]);
    }
  });
});
