import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { bakeOptionsFromArgv } from "../scripts/cmux-vm-image/bake";
import { runChild } from "./helpers/run-child";

// .github/workflows/cloud-vm-image-bake.yml runs only on dispatch and spends Freestyle
// resources, so its scripts are exercised here: each step's run script runs under bash with
// `bun` replaced by a stub that records its argv, and the step's env evaluated for the inputs.

type Step = { name?: string; id?: string; if?: string; env?: Record<string, string>; run?: string };
type Workflow = {
  on: { workflow_dispatch: { inputs: Record<string, { type: string; default: unknown }> } };
  jobs: { bake: { env: Record<string, string>; steps: Step[] } };
};

const workflowText = readFileSync(new URL("../../.github/workflows/cloud-vm-image-bake.yml", import.meta.url), "utf8");
// Bun's YAML parser; web/tests are typed by tests/bun-test.d.ts, which has no Bun global.
const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
const workflow = YAML.parse(workflowText) as Workflow;
const job = workflow.jobs.bake;
const step = (name: string) => {
  const found = job.steps.find((s) => s.name === name);
  if (!found?.run) throw new Error(`no run step ${name}`);
  return found;
};

type Inputs = { mode: string; clones: string; keep_snapshot: boolean; probes: boolean; agent_tools: boolean; team_vm: boolean; dev_tree: boolean };
const BASE: Inputs = { mode: "bake", clones: "2", keep_snapshot: true, probes: false, agent_tools: true, team_vm: false, dev_tree: false };

/** Evaluates the expression forms this workflow uses in env values. */
function evaluate(value: string, ctx: { inputs: Inputs; out: string; snapshot: string }): string {
  return value.replace(/\$\{\{\s*(.+?)\s*\}\}/g, (_, expr: string) => {
    const ternary = expr.match(/^inputs\.(\w+) && '([^']*)' \|\| '([^']*)'$/);
    if (ternary) return ctx.inputs[ternary[1] as keyof Inputs] ? ternary[2]! : ternary[3]!;
    const input = expr.match(/^inputs\.(\w+)$/);
    if (input) return String(ctx.inputs[input[1] as keyof Inputs]);
    const fixed: Record<string, string> = {
      "github.workspace": path.dirname(ctx.out),
      "github.run_id": "4242",
      "github.run_attempt": "1",
      "github.sha": "abc123def456",
      "secrets.FREESTYLE_API_KEY": "",
      "steps.bake.outputs.snapshot": ctx.snapshot,
    };
    if (expr in fixed) return fixed[expr]!;
    throw new Error(`unhandled expression ${expr}`);
  });
}

async function runStep(name: string, inputs: Inputs, dir: string, snapshot = "sh-test") {
  const out = path.join(dir, "cmux-vm-image-out");
  const bin = path.join(dir, "bin");
  mkdirSync(bin, { recursive: true });
  const stub = path.join(bin, "bun");
  writeFileSync(stub, `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${path.join(dir, "bun.argv")}"\ncase "$1" in *bake.ts) echo "IMAGE_ID ${snapshot}";; esac\n`);
  chmodSync(stub, 0o755);
  const ctx = { inputs, out, snapshot };
  const env: Record<string, string> = { PATH: `${bin}:${process.env.PATH}`, GITHUB_OUTPUT: path.join(dir, "github-output"), GITHUB_SHA: "0123456789abcdef0123456789abcdef01234567" };
  for (const [k, v] of Object.entries(job.env)) env[k] = evaluate(v, ctx);
  for (const [k, v] of Object.entries(step(name).env ?? {})) env[k] = evaluate(v, ctx);
  const result = await runChild("bash", ["-e", "-c", step(name).run!], { env, cwd: dir });
  const argv = (() => {
    try {
      return readFileSync(path.join(dir, "bun.argv"), "utf8").trim().split("\n");
    } catch {
      return [];
    }
  })();
  return { result, argv, env, out };
}

const dirs: string[] = [];
afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

describe("cloud-vm-image-bake.yml", () => {
  test("team_vm is a boolean input that defaults to off", () => {
    expect(workflow.on.workflow_dispatch.inputs.team_vm).toMatchObject({ type: "boolean", default: false });
  });

  test("dev_tree is a boolean input that defaults to off; bake.ts --dev-tree is dev only", () => {
    expect(workflow.on.workflow_dispatch.inputs.dev_tree).toMatchObject({ type: "boolean", default: false });
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t"]).devTree).toBe(false);
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--dev-tree"]).devTree).toBe(true);
    expect(() => bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--dev-tree", "--promotion"])).toThrow(/dev snapshots only/);
  });

  test("dev_tree=true: bake.ts gets --dev-tree, the after measurement runs on the baked snapshot, the candidate records it", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "cmux-bake-workflow-"));
    dirs.push(dir);
    const inputs = { ...BASE, dev_tree: true };
    const bake = await runStep("Bake", inputs, dir);
    expect(bake.result.status).toBe(0);
    expect(bake.argv.at(-1)).toBe(`../images/cmux-vm/bake.ts --tag ci-4242-1 --out-dir ${bake.out} --agent-tools --dev-tree`);
    const after = await runStep("First build after", inputs, dir);
    expect(after.result.status).toBe(0);
    expect(after.argv.at(-1)).toBe(`../images/cmux-vm/first-build.ts --mode after --snapshot sh-test --tag ci-4242-1 --ref 0123456789abcdef0123456789abcdef01234567 --out-dir ${after.out}`);
    writeFileSync(path.join(bake.out, "bake-cmuxnp-dev-vmimg-ci-4242-1.json"), JSON.stringify({ name: "cmuxnp-dev-vmimg-ci-4242-1", lockSha256: "f".repeat(64) }));
    writeFileSync(path.join(bake.out, "smoke-ci-4242-1.json"), JSON.stringify({ passed: true, checks: { a: { ok: true } } }));
    const candidate = await runStep("Dev channel candidate", inputs, dir);
    expect(candidate.result.status).toBe(0);
    expect(JSON.parse(readFileSync(path.join(bake.out, "channel-dev.json"), "utf8")).bake).toBe("images/cmux-vm/bake.ts --agent-tools --dev-tree (CI run 4242)");
    // Both sides build the run's commit, and a dev tree snapshot is kept only when its first build passed (not skipped or cancelled).
    expect(workflowText).toContain('first-build.ts --mode before --snapshot "$snapshot" --tag "$TAG" --ref "$GITHUB_SHA"');
    expect(workflowText).toContain("steps.smoke.outcome == 'success' && (!inputs.dev_tree || steps.first_build.outcome == 'success') && '--keep-snapshot'");
  });

  test("no run script interpolates an expression (inputs reach scripts through env only)", () => {
    for (const s of job.steps) if (s.run) expect(s.run).not.toContain("${{");
  });

  test("bake.ts --team-vm selects the team image", () => {
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t"]).teamVm).toBe(false);
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--team-vm"]).teamVm).toBe(true);
  });

  for (const teamVm of [false, true]) {
    test(`team_vm=${teamVm}: bake and smoke flags, names and the dev channel candidate`, async () => {
      const dir = mkdtempSync(path.join(tmpdir(), "cmux-bake-workflow-"));
      dirs.push(dir);
      const inputs = { ...BASE, team_vm: teamVm };

      const bake = await runStep("Bake", inputs, dir);
      expect(bake.result.status).toBe(0);
      const tag = teamVm ? "ci-team-4242-1" : "ci-4242-1";
      expect(bake.env.TAG).toBe(tag);
      expect(bake.argv.at(-1)).toBe(`../images/cmux-vm/bake.ts --tag ${tag} --out-dir ${bake.out} --agent-tools${teamVm ? " --team-vm" : ""}`);
      expect(readFileSync(path.join(dir, "github-output"), "utf8")).toContain("snapshot=sh-test");

      const smoke = await runStep("Smoke", inputs, dir);
      expect(smoke.result.status).toBe(0);
      expect(smoke.argv.at(-1)).toBe(`../images/cmux-vm/smoke.ts --snapshot sh-test --tag ${tag} --clones 2 --out-dir ${smoke.out}${teamVm ? " --team-vm" : ""}`);

      // What bake.ts and smoke.ts write into the out dir.
      const name = `cmuxnp-dev-vmimg-${tag}`;
      writeFileSync(path.join(bake.out, `bake-${name}.json`), JSON.stringify({ name, lockSha256: "f".repeat(64), ...(teamVm ? { teamFilesRoot: "/srv/team root:cmux-ssh 2750" } : {}) }));
      const smokeReport = path.join(bake.out, `smoke-${tag}.json`);
      writeFileSync(smokeReport, JSON.stringify({ passed: false, checks: { a: { ok: false } } }));
      const refused = await runStep("Dev channel candidate", inputs, dir);
      expect(refused.result.status).not.toBe(0);

      writeFileSync(smokeReport, JSON.stringify({ passed: true, checks: { a: { ok: true }, b: { ok: true } } }));
      const candidate = await runStep("Dev channel candidate", inputs, dir);
      expect(candidate.result.status).toBe(0);
      const recorded = JSON.parse(readFileSync(path.join(bake.out, "channel-dev.json"), "utf8"));
      expect(recorded).toMatchObject({
        schema: 1,
        env: "dev",
        var: teamVm ? "TEAM_VM_SNAPSHOT" : "CLOUD_FREESTYLE_SNAPSHOT",
        snapshot: name,
        snapshot_id: "sh-test",
        source_sha: "abc123def456",
        run: 4242,
        bake: `images/cmux-vm/bake.ts --agent-tools${teamVm ? " --team-vm" : ""} (CI run 4242)`,
        smoke: { result: "PASSED", detail: `smoke.ts --clones 2${teamVm ? " --team-vm" : ""} (CI run 4242): 2 checks passed` },
      });
      if (teamVm) expect(recorded.team_files_root).toBe("/srv/team root:cmux-ssh 2750");
      else expect(recorded).not.toHaveProperty("team_files_root");
    });
  }
});
