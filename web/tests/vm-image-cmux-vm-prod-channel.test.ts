import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { bakeOptionsFromArgv } from "../scripts/cmux-vm-image/bake";
import { imageResourceName, lockDigest } from "../scripts/cmux-vm-image/lock";
import { accountCheck, planCopy, recordedFlags } from "../scripts/cmux-vm-image/prod-copy";
import { recordCandidate, recordProductionCopy } from "../scripts/cmux-vm-image/promote-record";
import { runChild } from "./helpers/run-child";

// The production image channel (cloud-vm-image-bake.yml mode prod-copy, cloud-vm-image-promote.yml
// channel production): production runs in cmux-next-vm-image-prod and dev keeps cmux-next-vm-image-dev,
// a gate refuses before that environment is named while it is missing or not limited to feat-cmux-next,
// and the copy is the dev image's lock and flags on the production account, recorded as names.production.

type Step = { name?: string; if?: string; run?: string; env?: Record<string, string> };
type Job = { environment?: string; if?: string; needs?: string; env?: Record<string, string>; steps: Step[] };
type Workflow = { jobs: Record<string, Job> };

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
const load = (name: string) => YAML.parse(readFileSync(path.join(REPO, ".github/workflows", name), "utf8")) as Workflow;
const bakeWf = load("cloud-vm-image-bake.yml");
const promoteWf = load("cloud-vm-image-promote.yml");

/** Evaluates `${{ inputs.X == 'v' && 'a' || 'b' }}`, the one form these jobs' environment takes; throws on any other. */
function environmentFor(expr: string | undefined, inputs: Record<string, string>): string {
  const m = expr?.match(/^\$\{\{ inputs\.(\w+) == '([^']+)' && '([^']+)' \|\| '([^']+)' \}\}$/);
  if (!m) throw new Error(`unexpected environment ${JSON.stringify(expr)}`);
  return inputs[m[1]!] === m[2] ? m[3]! : m[4]!;
}

const ID = (n: number) => `sh-${n.toString(16).padStart(32, "0")}`;
const dirs: string[] = [];
const scratch = () => {
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-prod-channel-"));
  dirs.push(dir);
  return dir;
};
afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

describe("environments", () => {
  test("promote: channel production runs in cmux-next-vm-image-prod, channel dev keeps cmux-next-vm-image-dev", () => {
    expect(environmentFor(promoteWf.jobs.promote!.environment, { channel: "production" })).toBe("cmux-next-vm-image-prod");
    expect(environmentFor(promoteWf.jobs.promote!.environment, { channel: "dev" })).toBe("cmux-next-vm-image-dev");
  });

  test("bake: mode prod-copy runs in cmux-next-vm-image-prod, every other mode keeps cmux-next-vm-image-dev", () => {
    expect(environmentFor(bakeWf.jobs.bake!.environment, { mode: "prod-copy" })).toBe("cmux-next-vm-image-prod");
    for (const mode of ["bake", "repro"]) expect(environmentFor(bakeWf.jobs.bake!.environment, { mode })).toBe("cmux-next-vm-image-dev");
    expect(bakeWf.jobs["first-build-before"]!.environment).toBe("cmux-next-vm-image-dev");
    expect(bakeWf.jobs.bake!.needs).toBe("prod-gate");
    expect(bakeWf.jobs.bake!.if).toBe("${{ !cancelled() && (needs.prod-gate.result == 'success' || (inputs.mode != 'prod-copy' && needs.prod-gate.result == 'skipped')) }}");
    expect(bakeWf.jobs["prod-gate"]!.if).toBe("inputs.mode == 'prod-copy'");
  });

  test("no job names the production environment except the two gated ones", () => {
    const named = [bakeWf, promoteWf].flatMap((wf) => Object.entries(wf.jobs).filter(([, j]) => j.environment?.includes("cmux-next-vm-image-prod")).map(([n]) => n));
    expect(named).toEqual(["bake", "promote"]);
    for (const wf of [bakeWf, promoteWf]) expect(wf.jobs["prod-gate"]!.environment).toBeUndefined();
  });
});

describe("prod-gate", () => {
  const gate = (wf: Workflow) => wf.jobs["prod-gate"]!.steps.find((s) => s.name === "Check the production environment")!.run!;

  test("both workflows run the same gate", () => {
    expect(gate(bakeWf)).toBe(gate(promoteWf));
    for (const wf of [bakeWf, promoteWf]) expect(wf.jobs["prod-gate"]!.env).toEqual({ GH_TOKEN: "${{ github.token }}", PROD_ENV: "cmux-next-vm-image-prod" });
  });

  /** Runs the gate with `gh` stubbed: env.json is what GET environments/<name> returns (missing: 404), branches the policy names. */
  async function runGate(env: Record<string, unknown> | "missing", branches: string, ref = "refs/heads/feat-cmux-next") {
    const dir = scratch();
    const bin = path.join(dir, "bin");
    mkdirSync(bin);
    writeFileSync(path.join(dir, "env.json"), env === "missing" ? "" : JSON.stringify(env));
    writeFileSync(path.join(dir, "branches"), branches);
    writeFileSync(
      path.join(bin, "gh"),
      `#!/usr/bin/env bash\necho "$*" >> "${dir}/gh.argv"\ncase "$2" in\n  */deployment-branch-policies) cat "${dir}/branches";;\n  *) [ -s "${dir}/env.json" ] || { echo "HTTP 404" >&2; exit 1; }; cat "${dir}/env.json";;\nesac\n`,
    );
    chmodSync(path.join(bin, "gh"), 0o755);
    const result = await runChild("bash", ["-e", "-c", gate(promoteWf)], {
      env: { PATH: `${bin}:${process.env.PATH}`, RUNNER_TEMP: dir, GITHUB_REPOSITORY: "manaflow-ai/cmux", GITHUB_REF: ref, PROD_ENV: "cmux-next-vm-image-prod", GITHUB_OUTPUT: path.join(dir, "out") },
      cwd: dir,
    });
    const read = (f: string) => (existsSync(path.join(dir, f)) ? readFileSync(path.join(dir, f), "utf8") : "");
    return { ...result, argv: read("gh.argv"), output: read("out") };
  }
  const custom = { deployment_branch_policy: { custom_branch_policies: true, protected_branches: false } };

  test("passes when the environment exists and allows branch feat-cmux-next only", async () => {
    const r = await runGate(custom, "branch:feat-cmux-next");
    expect(r.status).toBe(0);
    expect(r.argv).toContain("api repos/manaflow-ai/cmux/environments/cmux-next-vm-image-prod");
    expect(r.stdout).toContain("allows branch feat-cmux-next only");
  });

  test("the account check uses the recorded production snapshot, with no environment anchor", () => {
    const plan = bakeWf.jobs.bake!.steps.find((s) => s.name === "Plan the production copy")!;
    expect(plan.env).not.toHaveProperty("FREESTYLE_PROD_ANCHOR");
    const promote = promoteWf.jobs.promote!.steps.find((s) => s.name === "Promote (fresh-clone smoke on the channel's account)")!;
    expect(promote.env).not.toHaveProperty("FREESTYLE_PROD_ANCHOR");
    expect(promote.run).not.toContain("FREESTYLE_PROD_ANCHOR");
  });

  test("every prod-copy step that holds the key passes it to bun only as a 0600 file", () => {
    const prodSteps = bakeWf.jobs.bake!.steps.filter((s) => s.env?.FREESTYLE_KEY_SECRET);
    expect(prodSteps.map((s) => s.name)).toEqual(["Plan the production copy", "Bake the production copy", "Smoke the production copy", "Delete everything this production copy run created"]);
    for (const s of prodSteps) {
      expect(s.env).not.toHaveProperty("FREESTYLE_API_KEY");
      const lines = s.run!.split("\n").filter((l) => l.trim() && !l.trim().startsWith("#"));
      expect(lines.slice(0, 3)).toEqual(["set -euo pipefail", 'key="$FREESTYLE_KEY_SECRET"', "unset FREESTYLE_KEY_SECRET"]);
      expect(s.run).toContain("trap 'rm -f \"$key_file\"' EXIT");
      for (const call of s.run!.match(/^.*\bbun .*$/gm) ?? []) if (!call.includes("prod-copy.ts plan")) expect(call).toContain('FREESTYLE_API_KEY_FILE="$key_file" bun ');
    }
    // No prod-copy step gets the raw key: the dev steps that do never run in prod-copy mode.
    for (const s of bakeWf.jobs.bake!.steps.filter((s) => s.env?.FREESTYLE_API_KEY)) expect(s.if ?? "").toMatch(/inputs\.mode == 'bake'|inputs\.mode == 'repro'|inputs\.mode != 'prod-copy'/);
  });

  const refused: Array<[string, Record<string, unknown> | "missing", string, string?]> = [
    ["a missing environment", "missing", "branch:feat-cmux-next"],
    ["no branch policy", { deployment_branch_policy: null }, "branch:feat-cmux-next"],
    ["protected branches instead of a custom policy", { deployment_branch_policy: { custom_branch_policies: false, protected_branches: true } }, ""],
    ["protected branches as well as a custom policy", { deployment_branch_policy: { custom_branch_policies: true, protected_branches: true } }, "branch:feat-cmux-next"],
    ["another branch allowed too", custom, "branch:feat-cmux-next,branch:main"],
    ["a tag policy", custom, "tag:feat-cmux-next"],
    ["no branch at all", custom, ""],
    ["a dispatch from another branch", custom, "branch:feat-cmux-next", "refs/heads/main"],
  ];
  for (const [label, env, branches, ref] of refused) {
    test(`refuses ${label}, saying production stays off`, async () => {
      const r = await runGate(env, branches, ref);
      expect(r.status).not.toBe(0);
      expect(r.stdout).toContain("::error title=Production environment::");
      if (!ref) expect(r.stdout).toContain("production stays off until cmux-next-vm-image-prod exists");
    });
  }
});

/** A repo root with the lock, dev.json (serving pointer and history) and wrangler.jsonc. */
function fakeRoot(entries: Array<Record<string, unknown>>): { root: string; lock: string } {
  const root = scratch();
  mkdirSync(path.join(root, "images/cmux-vm/channels"), { recursive: true });
  const lockText = '{ "schema": 1 }\n';
  writeFileSync(path.join(root, "images/cmux-vm/inputs.lock.json"), lockText);
  const dev = { schema: 1, env: "dev", snapshot: "cmuxnp-dev-vmimg-ci-100-1", snapshot_id: ID(100), history: entries };
  writeFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), `${JSON.stringify(dev, null, 2)}\n`);
  return { root, lock: lockDigest(lockText) };
}
const devEntry = (lock: string, over: Record<string, unknown> = {}) => ({
  snapshot: "cmuxnp-dev-vmimg-ci-300-1",
  snapshot_id: ID(300),
  var: "CLOUD_FREESTYLE_SNAPSHOT",
  lock_sha256: lock,
  source_sha: "41c5481957f3",
  run: 300,
  bake: "images/cmux-vm/bake.ts --agent-tools (CI run 300)",
  smoke: { result: "PASSED" },
  ...over,
});
const devHistory = (root: string) => (JSON.parse(readFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), "utf8")) as { history: Array<Record<string, unknown>> }).history;

describe("prod-copy.ts plan", () => {
  test("repeats the dev image's flags, with --prod-copy first", () => {
    const { root, lock } = fakeRoot([]);
    for (const [bake, v, flags] of [
      ["images/cmux-vm/bake.ts --agent-tools (CI run 300)", "CLOUD_FREESTYLE_SNAPSHOT", ["--prod-copy", "--agent-tools"]],
      ["images/cmux-vm/bake.ts (CI run 300)", "CLOUD_FREESTYLE_SNAPSHOT", ["--prod-copy"]],
      ["images/cmux-vm/bake.ts --agent-tools --team-vm (CI run 300)", "TEAM_VM_SNAPSHOT", ["--prod-copy", "--agent-tools", "--team-vm"]],
    ] as const) {
      writeFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), JSON.stringify({ history: [devEntry(lock, { bake, var: v })] }));
      expect(planCopy(root, ID(300))).toEqual({ flags: [...flags], var: v, lockSha256: lock });
    }
  });

  const refused: Array<[string, Record<string, unknown>, RegExp]> = [
    ["a failed smoke", { smoke: { result: "FAILED" } }, /not "PASSED"/],
    ["a local bake (no run)", { run: undefined, bake: "images/cmux-vm/bake.ts --agent-tools (local run)" }, /not a CI bake/],
    ["a dev tree bake", { bake: "images/cmux-vm/bake.ts --agent-tools --dev-tree (CI run 300)" }, /dev tree/],
    ["an unknown flag", { bake: "images/cmux-vm/bake.ts --update-lock (CI run 300)" }, /not all copyable/],
    ["another lock", { lock_sha256: "0".repeat(64) }, /other inputs/],
    ["a var that disagrees with --team-vm", { var: "TEAM_VM_SNAPSHOT" }, /disagree/],
    ["an entry that already has a copy", { names: { production: { snapshot: "cmuxnp-prod-vmimg-x", snapshot_id: ID(9) } } }, /already records names.production/],
  ];
  for (const [label, over, message] of refused) {
    test(`refuses ${label}`, () => {
      const { root, lock } = fakeRoot([]);
      writeFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), JSON.stringify({ history: [devEntry(lock, over)] }));
      expect(() => planCopy(root, ID(300))).toThrow(message);
    });
  }

  test("refuses an id that is not recorded, and a value that is not an id", () => {
    const { root, lock } = fakeRoot([]);
    writeFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), JSON.stringify({ history: [devEntry(lock)] }));
    expect(() => planCopy(root, ID(301))).toThrow(/not in images\/cmux-vm\/channels\/dev.json history/);
    expect(() => planCopy(root, "sh-x; true")).toThrow(/not a snapshot id/);
  });

  test("reads the flags a CI candidate records, and nothing else", () => {
    expect(recordedFlags("images/cmux-vm/bake.ts --agent-tools --team-vm (CI run 7)")).toEqual(["--agent-tools", "--team-vm"]);
    expect(recordedFlags("images/cmux-vm/bake.ts --agent-tools (local run, dev key)")).toBeUndefined();
    expect(recordedFlags(undefined)).toBeUndefined();
  });

  test("the real dev channel's newest CI entry is copyable or refused with a reason (never throws on shape)", () => {
    const dev = JSON.parse(readFileSync(path.join(REPO, "images/cmux-vm/channels/dev.json"), "utf8")) as { history: Array<{ snapshot_id: string; run?: number }> };
    const ci = dev.history.filter((h) => typeof h.run === "number").at(-1);
    if (!ci) return;
    try {
      expect(planCopy(REPO, ci.snapshot_id).flags[0]).toBe("--prod-copy");
    } catch (error) {
      expect(String(error)).toContain("refusing a production copy");
    }
  });
});

describe("prod-copy.ts account-check", () => {
  test("refuses the dev account's key: it resolves the dev channel's snapshot to its recorded id", async () => {
    const { root } = fakeRoot([]);
    await expect(accountCheck(root, async (n) => (n === "cmuxnp-dev-vmimg-ci-100-1" ? ID(100) : undefined))).rejects.toThrow(/dev account's key/);
  });

  test("refuses a third-account key before any production snapshot is recorded", async () => {
    const { root } = fakeRoot([]);
    const asked: string[] = [];
    // Another account cannot see the dev slug (404); that is not proof of production identity.
    await expect(accountCheck(root, async (n) => (asked.push(n), undefined))).rejects.toThrow(/no trusted production snapshot/);
    expect(asked).toEqual(["cmuxnp-dev-vmimg-ci-100-1"]);
  });

  test("refuses the dev key when its recorded dev snapshot was deleted and no production anchor exists", async () => {
    const { root } = fakeRoot([]);
    // The dev key is valid, but the dev slug was deleted: the provider returns 404 too.
    const devAccount = new Map([["cmuxnp-dev-vmimg-other", ID(101)]]);
    await expect(accountCheck(root, async (name) => devAccount.get(name))).rejects.toThrow(/no trusted production snapshot/);
  });

  test("once production snapshots are recorded, the key must resolve one of them to its id: a third account is refused", async () => {
    const { root, lock } = fakeRoot([]);
    const recorded = { snapshot: "cmuxnp-prod-vmimg-ci-400-1", snapshot_id: ID(400) };
    const dev = JSON.parse(readFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), "utf8"));
    dev.history = [devEntry(lock, { names: { production: recorded } })];
    writeFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), JSON.stringify(dev));
    const prodAccount = async (n: string) => (n === recorded.snapshot ? recorded.snapshot_id : undefined);
    expect(await accountCheck(root, prodAccount)).toContain(`${recorded.snapshot} resolves to the recorded ${recorded.snapshot_id}`);
    await expect(accountCheck(root, async () => undefined)).rejects.toThrow(/not the production account's key/);
    // A slug re-baked on another account resolves to another id: refused.
    await expect(accountCheck(root, async (n) => (n === recorded.snapshot ? ID(401) : undefined))).rejects.toThrow(/not the production account's key/);
    // The serving production pointer counts too, and a dev-named entry there is never an anchor.
    writeFileSync(path.join(root, "images/cmux-vm/channels/production.json"), JSON.stringify({ snapshot: "cmuxnp-prod-vmimg-ci-500-1", snapshot_id: ID(500), previous: { snapshot: "cmuxnp-dev-vmimg-ci-100-1", snapshot_id: ID(100) } }));
    expect(await accountCheck(root, async (n) => (n === "cmuxnp-prod-vmimg-ci-500-1" ? ID(500) : undefined))).toContain("account check passed");
    await expect(accountCheck(root, async (n) => (n === "cmuxnp-dev-vmimg-ci-100-1" ? ID(100) : undefined))).rejects.toThrow(/dev account's key/);
  });

  test("fails closed when a recorded production pointer is malformed", async () => {
    const current = fakeRoot([]);
    writeFileSync(path.join(current.root, "images/cmux-vm/channels/production.json"), JSON.stringify({ snapshot: "cmuxnp-prod-vmimg-ci-500-1" }));
    await expect(accountCheck(current.root, async () => undefined)).rejects.toThrow(/production\.json current is malformed/);

    const team = fakeRoot([]);
    writeFileSync(path.join(team.root, "images/cmux-vm/channels/production.json"), JSON.stringify({
      snapshot: "cmuxnp-prod-vmimg-ci-500-1",
      snapshot_id: ID(500),
      team_vm: { snapshot: "cmuxnp-prod-vmimg-team-500-1" },
    }));
    await expect(accountCheck(team.root, async () => undefined)).rejects.toThrow(/production\.json team_vm is malformed/);

    const history = fakeRoot([devEntry(current.lock, { names: { production: { snapshot: "cmuxnp-prod-vmimg-ci-500-1" } } })]);
    await expect(accountCheck(history.root, async () => undefined)).rejects.toThrow(/names\.production is malformed/);

    const metadata = fakeRoot([]);
    writeFileSync(path.join(metadata.root, "images/cmux-vm/channels/production.json"), JSON.stringify({ schema: 1, bogus: true }));
    await expect(accountCheck(metadata.root, async () => undefined)).rejects.toThrow(/production\.json current is malformed/);

    const teamMetadata = fakeRoot([]);
    writeFileSync(path.join(teamMetadata.root, "images/cmux-vm/channels/production.json"), JSON.stringify({ schema: 1, env: "production", team_vm: { bogus: true } }));
    await expect(accountCheck(teamMetadata.root, async () => undefined)).rejects.toThrow(/production\.json team_vm is malformed/);
  });

  test("accepts the normal first production and team-only channel record shapes", async () => {
    const first = fakeRoot([]);
    writeFileSync(path.join(first.root, "images/cmux-vm/channels/production.json"), JSON.stringify({
      schema: 1,
      env: "production",
      snapshot: "cmuxnp-prod-vmimg-ci-500-1",
      snapshot_id: ID(500),
      previous: null,
    }));
    expect(await accountCheck(first.root, async (n) => (n === "cmuxnp-prod-vmimg-ci-500-1" ? ID(500) : undefined))).toContain("account check passed");

    const team = fakeRoot([]);
    writeFileSync(path.join(team.root, "images/cmux-vm/channels/production.json"), JSON.stringify({
      schema: 1,
      env: "production",
      team_vm: { snapshot: "cmuxnp-prod-vmimg-team-500-1", snapshot_id: ID(501), previous: null },
    }));
    expect(await accountCheck(team.root, async (n) => (n === "cmuxnp-prod-vmimg-team-500-1" ? ID(501) : undefined))).toContain("account check passed");
  });

  test("fails closed without a dev pointer to check against", async () => {
    const root = scratch();
    mkdirSync(path.join(root, "images/cmux-vm/channels"), { recursive: true });
    writeFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), JSON.stringify({ snapshot: "cmuxnp-dev-vmimg-x" }));
    await expect(accountCheck(root, async () => undefined)).rejects.toThrow(/refusing/);
  });
});

describe("promote-record.ts --production-copy", () => {
  const copy = (lock: string, over: Record<string, unknown> = {}) => ({
    schema: 1,
    env: "production",
    copy_of: ID(300),
    var: "CLOUD_FREESTYLE_SNAPSHOT",
    snapshot: "cmuxnp-prod-vmimg-ci-400-1",
    snapshot_id: ID(400),
    lock_sha256: lock,
    source_sha: "0123456789abcdef0123456789abcdef01234567",
    run: 400,
    baked_at: "2026-10-28T00:00:00Z",
    bake: "images/cmux-vm/bake.ts --prod-copy --agent-tools (CI run 400)",
    smoke: { result: "PASSED", at: "2026-10-28T00:00:00Z", detail: "smoke.ts --clones 2 (CI run 400): 25 checks passed" },
    ...over,
  });

  test("records names.production on the dev entry, once; the entry is otherwise unchanged", () => {
    const { root, lock } = fakeRoot([]);
    writeFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), JSON.stringify({ history: [devEntry(lock)] }));
    expect(recordProductionCopy(root, copy(lock), ID(300), "400")).toEqual({ var: "CLOUD_FREESTYLE_SNAPSHOT", appended: true });
    const { schema: _s, env: _e, copy_of: _c, ...recorded } = copy(lock);
    expect(devHistory(root)).toEqual([{ ...devEntry(lock), names: { production: recorded } }]);
    expect(recordProductionCopy(root, copy(lock), ID(300), "400")).toEqual({ var: "CLOUD_FREESTYLE_SNAPSHOT", appended: false });
    expect(() => recordProductionCopy(root, copy(lock, { snapshot_id: ID(401) }), ID(300), "400")).toThrow(/never replaced/);
  });

  test("the dev candidate still re-records (a dev promote re-run) after its production copy is recorded", () => {
    const { root, lock } = fakeRoot([]);
    const candidate = { schema: 1, env: "dev", ...devEntry(lock) };
    expect(recordCandidate(root, candidate, ID(300), "300").appended).toBe(true);
    expect(recordProductionCopy(root, copy(lock), ID(300), "400").appended).toBe(true);
    expect(recordCandidate(root, candidate, ID(300), "300")).toEqual({ var: "CLOUD_FREESTYLE_SNAPSHOT", appended: false });
    expect(devHistory(root).at(-1)!.names).toBeDefined();
  });

  const refused: Array<[string, (lock: string) => Record<string, unknown>, string?, string?]> = [
    ["a dev candidate", (l) => copy(l, { env: "dev" })],
    ["a copy of another image", (l) => copy(l, { copy_of: ID(301) })],
    ["another run", (l) => copy(l), ID(300), "401"],
    ["a failed smoke", (l) => copy(l, { smoke: { result: "FAILED" } })],
    ["a dev-named snapshot", (l) => copy(l, { snapshot: "cmuxnp-dev-vmimg-ci-400-1" })],
    ["the dev image's own id", (l) => copy(l, { snapshot_id: ID(300) })],
    ["another var", (l) => copy(l, { var: "TEAM_VM_SNAPSHOT" })],
    ["another lock", (l) => copy(l, { lock_sha256: "0".repeat(64) })],
    ["an unrecorded dev image", (l) => copy(l, { copy_of: ID(302) }), ID(302)],
  ];
  for (const [label, make, snapshot, run] of refused) {
    test(`refuses ${label} and leaves dev.json alone`, () => {
      const { root, lock } = fakeRoot([]);
      writeFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), JSON.stringify({ history: [devEntry(lock)] }));
      const before = readFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), "utf8");
      expect(() => recordProductionCopy(root, make(lock), snapshot ?? ID(300), run ?? "400")).toThrow(/refusing|not a/);
      expect(readFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), "utf8")).toBe(before);
    });
  }
});

describe("bake.ts --prod-copy", () => {
  test("names the snapshot cmuxnp-prod-vmimg-<tag>, the prefix the production Worker boots", () => {
    expect(imageResourceName({ promotion: false, prodCopy: true, tag: "ci-400-1", date: "20261028", sha: "abc" })).toBe("cmuxnp-prod-vmimg-ci-400-1");
    expect(imageResourceName({ promotion: false, tag: "ci-400-1", date: "20261028", sha: "abc" })).toBe("cmuxnp-dev-vmimg-ci-400-1");
    expect(() => imageResourceName({ promotion: true, prodCopy: true, tag: "x", date: "", sha: "" })).toThrow();
  });

  test("takes the dev image's flags but never a dev tree, a new lock or --promotion", () => {
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--prod-copy", "--agent-tools", "--team-vm"])).toMatchObject({ prodCopy: true, agentTools: true, teamVm: true });
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t"]).prodCopy).toBe(false);
    for (const extra of ["--dev-tree", "--update-lock", "--promotion"]) expect(() => bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--prod-copy", extra])).toThrow();
  });
});

describe("promote step on production", () => {
  test("the key reaches account-check and promote.ts only as a 0600 file; the test profile reaches promote.ts", async () => {
    const step = promoteWf.jobs.promote!.steps.find((s) => s.name === "Promote (fresh-clone smoke on the channel's account)")!;
    const dir = scratch();
    const bin = path.join(dir, "bin");
    mkdirSync(bin);
    mkdirSync(path.join(dir, "web"));
    const record = path.join(dir, "bun.seen");
    writeFileSync(
      path.join(bin, "bun"),
      `#!/usr/bin/env bash\n{ echo "argv $*"; env | grep -c 's3cr3t-key' || true; stat -c %a "$FREESTYLE_API_KEY_FILE" 2>/dev/null || stat -f %Lp "$FREESTYLE_API_KEY_FILE"; echo "email=$CMUX_UITEST_STACK_EMAIL password=$CMUX_UITEST_STACK_PASSWORD token=$GH_TOKEN"; } >> "${record}"\n`,
    );
    chmodSync(path.join(bin, "bun"), 0o755);
    // The step's other commands record it if a production value is in their environment, then run the real one.
    for (const cmd of ["mktemp", "chmod", "mkdir", "tee", "rm"]) {
      const real = (await runChild("bash", ["-c", `command -v ${cmd}`])).stdout.trim();
      writeFileSync(path.join(bin, cmd), `#!/usr/bin/env bash\ncase "$(/usr/bin/env)" in *s3cr3t-key*|*agent@example.com*|*CMUX_UITEST_STACK_PASSWORD=pw*|*GH_TOKEN=t*) echo ${cmd} >> "${path.join(dir, "leaks")}";; esac\nexec ${real} "$@"\n`);
      chmodSync(path.join(bin, cmd), 0o755);
    }
    const run = async (channel: string, email: string) => {
      rmSync(record, { force: true });
      const env = { PATH: `${bin}:${process.env.PATH}`, FREESTYLE_KEY_SECRET: "s3cr3t-key", RUNNER_TEMP: dir, OUT_DIR: path.join(dir, "out"), CHANNEL: channel, SNAPSHOT: ID(300), SNAPSHOT_VAR: "CLOUD_FREESTYLE_SNAPSHOT", CMUX_UITEST_STACK_EMAIL: email, CMUX_UITEST_STACK_PASSWORD: email && "pw", GH_TOKEN: email && "t" };
      const result = await runChild("bash", ["-e", "-c", step.run!], { env, cwd: path.join(dir, "web") });
      expect(result.status).toBe(0);
      expect(`${result.stdout}${result.stderr}`).not.toContain("s3cr3t-key");
      return readFileSync(record, "utf8").trim().split("\n");
    };
    // account-check sees none of the test profile or the token; promote.ts (the compat gate) gets them.
    expect(await run("production", "agent@example.com")).toEqual([
      "argv scripts/cmux-vm-image/prod-copy.ts account-check",
      "0",
      "600",
      "email= password= token=",
      `argv ../images/cmux-vm/promote.ts --channel production --snapshot ${ID(300)} --var CLOUD_FREESTYLE_SNAPSHOT`,
      "0",
      "600",
      "email=agent@example.com password=pw token=t",
    ]);
    // dev: no account check, and nothing of production's reaches promote.ts.
    expect(await run("dev", "leak@example.com")).toEqual([`argv ../images/cmux-vm/promote.ts --channel dev --snapshot ${ID(300)} --var CLOUD_FREESTYLE_SNAPSHOT`, "0", "600", "email= password= token="]);
    // Every other command the step runs (mktemp, chmod, mkdir, tee, rm) saw none of them either.
    expect(existsSync(path.join(dir, "leaks")) ? readFileSync(path.join(dir, "leaks"), "utf8") : "").toBe("");
  });

  test("the diff carries channels/production.json for production, as a new file the first time", async () => {
    const step = promoteWf.jobs.promote!.steps.find((s) => s.name === "Diff for the channel PR")!;
    const dir = scratch();
    const gitEnv = { PATH: process.env.PATH, HOME: dir, GIT_CONFIG_NOSYSTEM: "1" };
    const git = async (...args: string[]) => expect((await runChild("git", args, { cwd: dir, env: gitEnv })).status).toBe(0);
    mkdirSync(path.join(dir, "images/cmux-vm/channels"), { recursive: true });
    mkdirSync(path.join(dir, "backend/apps/api"), { recursive: true });
    mkdirSync(path.join(dir, "web"));
    writeFileSync(path.join(dir, "images/cmux-vm/channels/dev.json"), "{}\n");
    writeFileSync(path.join(dir, "backend/apps/api/wrangler.jsonc"), "{}\n");
    await git("init", "-q");
    await git("add", "-A");
    await git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "seed");
    writeFileSync(path.join(dir, "images/cmux-vm/channels/production.json"), '{ "env": "production" }\n');
    writeFileSync(path.join(dir, "backend/apps/api/wrangler.jsonc"), '{ "x": 1 }\n');
    const out = path.join(dir, "out");
    mkdirSync(out);
    for (const channel of ["dev", "production"]) {
      writeFileSync(path.join(dir, "gh-output"), "");
      const result = await runChild("bash", ["-e", "-c", step.run!], { env: { ...gitEnv, FREESTYLE_KEY_SECRET: "zz-not-in-the-diff", OUT_DIR: out, CHANNEL: channel, SNAPSHOT: ID(300), GITHUB_OUTPUT: path.join(dir, "gh-output") }, cwd: path.join(dir, "web") });
      expect(result.status).toBe(0);
      const diff = readFileSync(path.join(out, `promote-${channel}-${ID(300)}.diff`), "utf8");
      expect(diff).toContain("backend/apps/api/wrangler.jsonc");
      if (channel === "dev") expect(diff).not.toContain("production.json");
      else expect(diff).toContain("new file mode 100644\nindex 0000000..");
    }
  });
});
