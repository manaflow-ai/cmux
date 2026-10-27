import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { deleteSnapshot, snapshotReferences } from "../scripts/cmux-vm-image/cleanup";
import { recordCandidate } from "../scripts/cmux-vm-image/promote-record";
import { runChild } from "./helpers/run-child";

// .github/workflows/cloud-vm-image-promote.yml runs only on dispatch with the cmux-next dev
// Freestyle key, so its trust boundary is pinned here: read-only token, the bake's environment,
// no pull_request_target, the key only through a 0600 file, and delete_snapshot's reference
// refusal (cleanup.ts --snapshot) against channel files and wrangler.jsonc.

type Step = { name?: string; id?: string; if?: string; uses?: string; env?: Record<string, string>; with?: Record<string, unknown>; run?: string; "working-directory"?: string };
type Job = { environment?: string; permissions?: unknown; env: Record<string, string>; steps: Step[] };
type Workflow = {
  on: Record<string, { inputs: Record<string, { type: string; options?: string[]; default?: unknown }> }>;
  permissions: Record<string, string>;
  concurrency: { group: string; "cancel-in-progress": unknown };
  jobs: Record<string, Job>;
};

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const workflowText = readFileSync(path.join(REPO, ".github/workflows/cloud-vm-image-promote.yml"), "utf8");
const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
const workflow = YAML.parse(workflowText) as Workflow;
const job = workflow.jobs.promote!;
const step = (name: string) => {
  const found = job.steps.find((s) => s.name === name);
  if (!found?.run) throw new Error(`no run step ${name}`);
  return found;
};

const ID = (n: number) => `sh-${n.toString(16).padStart(32, "0")}`;
const dirs: string[] = [];
const scratch = () => {
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-promote-workflow-"));
  dirs.push(dir);
  return dir;
};
afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

describe("cloud-vm-image-promote.yml trust boundary", () => {
  test("dispatch only, never pull_request_target", () => {
    expect(Object.keys(workflow.on)).toEqual(["workflow_dispatch"]);
    expect(workflowText).not.toContain("pull_request_target");
  });

  test("permissions are exactly contents: read and actions: read, and no job widens them", () => {
    expect(workflow.permissions).toEqual({ contents: "read", actions: "read" });
    for (const j of Object.values(workflow.jobs)) expect(j.permissions).toBeUndefined();
    expect(workflowText).not.toMatch(/:\s*write\b|write-all/);
  });

  test("one job, in the bake's environment", () => {
    expect(Object.keys(workflow.jobs)).toEqual(["promote"]);
    expect(job.environment).toBe("cmux-next-vm-image-dev");
  });

  test("never cancels a running promotion", () => {
    expect(workflow.concurrency["cancel-in-progress"]).toBe(false);
  });

  test("channel is dev only", () => {
    expect(workflow.on.workflow_dispatch!.inputs.channel).toMatchObject({ type: "choice", options: ["dev"] });
  });

  test("nothing publishes: no push, no PR, no credentials kept by checkout", () => {
    expect(workflowText).not.toMatch(/git push|gh pr |gh api [^\n]*-X|--method/);
    const checkout = job.steps.find((s) => s.uses?.startsWith("actions/checkout@"));
    expect(checkout?.with?.["persist-credentials"]).toBe(false);
  });

  test("no run script interpolates an expression (inputs reach scripts through env only)", () => {
    for (const s of job.steps) if (s.run) expect(s.run).not.toContain("${{");
  });

  test("the key is only FREESTYLE_KEY_SECRET in step env; a step that runs bun unsets it and passes a file", () => {
    expect([...workflowText.matchAll(/secrets\.[A-Za-z_]+/g)].map((m) => m[0]).every((s) => s === "secrets.FREESTYLE_API_KEY")).toBe(true);
    expect(job.env).not.toHaveProperty("FREESTYLE_KEY_SECRET");
    for (const s of job.steps) {
      for (const [k, v] of Object.entries(s.env ?? {})) if (v.includes("secrets.")) expect(k).toBe("FREESTYLE_KEY_SECRET");
      expect(s.env ?? {}).not.toHaveProperty("FREESTYLE_API_KEY");
      // Before any external command runs, the key leaves the environment (an unexported shell variable).
      if (s.env?.FREESTYLE_KEY_SECRET) {
        const lines = s.run!.split("\n").filter((l) => l.trim() && !l.trim().startsWith("#"));
        expect(lines.slice(0, 3)).toEqual(["set -euo pipefail", 'key="$FREESTYLE_KEY_SECRET"', "unset FREESTYLE_KEY_SECRET"]);
        expect(s.run!.split("FREESTYLE_KEY_SECRET").length).toBe(3);
      }
      if (s.env?.FREESTYLE_KEY_SECRET && s.run?.includes("bun ")) {
        const run = s.run;
        expect(run.indexOf("unset FREESTYLE_KEY_SECRET")).toBeGreaterThan(-1);
        expect(run.indexOf("unset FREESTYLE_KEY_SECRET")).toBeLessThan(run.indexOf("bun "));
        expect(run).toContain('FREESTYLE_API_KEY_FILE="$key_file" bun ');
        expect(run).toContain("trap 'rm -f \"$key_file\"' EXIT");
      }
    }
  });
});

async function runScript(name: string, env: Record<string, string>, dir: string) {
  return runChild("bash", ["-e", "-c", step(name).run!], { env: { PATH: process.env.PATH, ...env }, cwd: dir });
}

describe("Check the inputs", () => {
  const base = { CHANNEL: "dev", SNAPSHOT: ID(1), BAKE_RUN: "40270232246", DELETE_SNAPSHOT: "", GITHUB_REF: "refs/heads/feat-cmux-next" };
  const cases: Array<[string, Partial<typeof base>, string | null]> = [
    ["promote", {}, "promote=true\ndelete=false\n"],
    ["promote and delete", { DELETE_SNAPSHOT: ID(2) }, "promote=true\ndelete=true\n"],
    ["delete only", { SNAPSHOT: "", BAKE_RUN: "", DELETE_SNAPSHOT: ID(2) }, "promote=false\ndelete=true\n"],
    ["staging", { CHANNEL: "staging" }, null],
    ["production", { CHANNEL: "production" }, null],
    ["another branch", { GITHUB_REF: "refs/heads/main" }, null],
    ["nothing", { SNAPSHOT: "", BAKE_RUN: "" }, null],
    ["snapshot without bake_run", { BAKE_RUN: "" }, null],
    ["bake_run without snapshot", { SNAPSHOT: "", DELETE_SNAPSHOT: ID(2) }, null],
    ["a bad snapshot id", { SNAPSHOT: "sh-x; rm -rf /" }, null],
    ["a bad delete id", { DELETE_SNAPSHOT: "cmuxnp-dev-vmimg-x" }, null],
    ["deleting the snapshot being promoted", { DELETE_SNAPSHOT: ID(1) }, null],
  ];
  for (const [label, override, outputs] of cases) {
    test(`${label}: ${outputs ? "accepted" : "refused"}`, async () => {
      const dir = scratch();
      const out = path.join(dir, "out");
      writeFileSync(out, "");
      const result = await runScript("Check the inputs", { ...base, ...override, GITHUB_OUTPUT: out }, dir);
      if (outputs) {
        expect(result.status).toBe(0);
        expect(readFileSync(out, "utf8")).toBe(outputs);
      } else {
        expect(result.status).not.toBe(0);
        expect(result.stdout).toContain("::error");
      }
    });
  }
});

describe("key handling in the run scripts", () => {
  for (const name of ["Promote (fresh-clone smoke on the dev account)", "Delete the spare snapshot"]) {
    test(`${name}: bun sees a 0600 key file, not the key; the file is gone afterwards`, async () => {
      const dir = scratch();
      const bin = path.join(dir, "bin");
      mkdirSync(bin);
      const record = path.join(dir, "bun.seen");
      // The stub records its argv, whether the key is in its environment, and the key file's mode and contents.
      writeFileSync(
        path.join(bin, "bun"),
        `#!/usr/bin/env bash\n{ echo "argv $*"; env | grep -c 's3cr3t-key' || true; echo "file $FREESTYLE_API_KEY_FILE"; stat -c %a "$FREESTYLE_API_KEY_FILE" 2>/dev/null || stat -f %Lp "$FREESTYLE_API_KEY_FILE"; cat "$FREESTYLE_API_KEY_FILE"; echo; } > "${record}"\n`,
      );
      chmodSync(path.join(bin, "bun"), 0o755);
      // Every other external command the step runs records it if the key is in its environment, then runs the real one.
      const leaks = path.join(dir, "leaks");
      for (const cmd of ["mktemp", "chmod", "git", "mkdir", "rm", "tee", "tr", "sed", "cat"]) {
        const real = (await runChild("bash", ["-c", `command -v ${cmd}`])).stdout.trim();
        writeFileSync(path.join(bin, cmd), `#!/usr/bin/env bash\ncase "$(/usr/bin/env)" in *s3cr3t-key*) echo ${cmd} >> "${leaks}";; esac\nexec ${real} "$@"\n`);
        chmodSync(path.join(bin, cmd), 0o755);
      }
      // The shims do catch a leak.
      await runChild(path.join(bin, "tr"), ["a", "b"], { env: { PATH: process.env.PATH, FREESTYLE_KEY_SECRET: "s3cr3t-key" } });
      expect(readFileSync(leaks, "utf8")).toBe("tr\n");
      rmSync(leaks);
      mkdirSync(path.join(dir, "web"));
      // The delete step fetches the branch tip from origin: a local bare clone of a seed repo with the reference files.
      const gitEnv = { PATH: process.env.PATH, HOME: dir, GIT_CONFIG_NOSYSTEM: "1" };
      const git = async (args: string[], cwd = dir) => expect((await runChild("git", args, { cwd, env: gitEnv })).status).toBe(0);
      const seed = path.join(dir, "seed");
      mkdirSync(path.join(seed, "images/cmux-vm/channels"), { recursive: true });
      mkdirSync(path.join(seed, "backend/apps/api"), { recursive: true });
      writeFileSync(path.join(seed, "images/cmux-vm/channels/dev.json"), "{}\n");
      writeFileSync(path.join(seed, "images/cmux-vm/channels/staging.json"), '{ "snapshot_id": "x" }\n');
      // git quotes this name in line output; the step must still copy it.
      writeFileSync(path.join(seed, "images/cmux-vm/channels/é x.json"), '{ "snapshot_id": "y" }\n');
      writeFileSync(path.join(seed, "backend/apps/api/wrangler.jsonc"), "{}\n");
      await git(["init", "-q", "-b", "feat-cmux-next", seed]);
      await git(["add", "-A"], seed);
      await git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "seed"], seed);
      await git(["clone", "-q", "--bare", seed, path.join(dir, "origin.git")]);
      await git(["init", "-q"]);
      await git(["remote", "add", "origin", path.join(dir, "origin.git")]);
      const env = {
        PATH: `${bin}:${process.env.PATH}`,
        FREESTYLE_KEY_SECRET: "s3cr3t-key",
        RUNNER_TEMP: dir,
        OUT_DIR: path.join(dir, "out"),
        GITHUB_STEP_SUMMARY: path.join(dir, "summary"),
        CHANNEL: "dev",
        SNAPSHOT: ID(1),
        SNAPSHOT_VAR: "CLOUD_FREESTYLE_SNAPSHOT",
        DELETE_SNAPSHOT: ID(2),
      };
      const result = await runChild("bash", ["-e", "-c", step(name).run!], { env: { ...env, HOME: dir, GIT_CONFIG_NOSYSTEM: "1" }, cwd: path.join(dir, "web") });
      expect(result.status).toBe(0);
      const [argv, inEnv, file, mode, key] = readFileSync(record, "utf8").split("\n");
      expect(argv).not.toContain("s3cr3t-key");
      if (name === "Delete the spare snapshot") {
        expect(argv).toBe(`argv ../images/cmux-vm/cleanup.ts --snapshot ${ID(2)} --also-root ${dir}/branch-tip`);
        expect(readFileSync(path.join(dir, "branch-tip/images/cmux-vm/channels/dev.json"), "utf8")).toBe("{}\n");
        expect(readFileSync(path.join(dir, "branch-tip/images/cmux-vm/channels/staging.json"), "utf8")).toBe('{ "snapshot_id": "x" }\n');
        expect(readFileSync(path.join(dir, "branch-tip/images/cmux-vm/channels/é x.json"), "utf8")).toBe('{ "snapshot_id": "y" }\n');
        expect(existsSync(path.join(dir, "branch-tip/backend/apps/api/wrangler.jsonc"))).toBe(true);
      }
      expect(inEnv).toBe("0");
      expect(existsSync(leaks) ? readFileSync(leaks, "utf8") : "").toBe("");
      expect(file!.startsWith(`file ${dir}/freestyle-key.`)).toBe(true);
      expect(mode).toBe("600");
      expect(key).toBe("s3cr3t-key");
      expect(existsSync(file!.slice(5))).toBe(false);
      expect(`${result.stdout}${result.stderr}`).not.toContain("s3cr3t-key");
    });
  }
});

/** A repo root with the channel files and wrangler.jsonc the reference check reads. */
function fakeRoot(): string {
  const root = scratch();
  mkdirSync(path.join(root, "images/cmux-vm/channels"), { recursive: true });
  mkdirSync(path.join(root, "backend/apps/api"), { recursive: true });
  const dev = {
    schema: 1,
    env: "dev",
    snapshot: "cmuxnp-dev-vmimg-ci-100-1",
    snapshot_id: ID(100),
    previous: { snapshot: "cmuxnp-dev-vmimg-ci-99-1", snapshot_id: ID(99) },
    also_kept: `cmuxnp-dev-vmimg-auto4 (${ID(4)}), superseded`,
    team_vm: { snapshot: "cmuxnp-dev-vmimg-ci-team-7-1", snapshot_id: ID(7) },
    history: [{ snapshot: "cmuxnp-dev-vmimg-ci-50-1", snapshot_id: ID(50), smoke: { result: "PASSED" } }],
  };
  writeFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), `${JSON.stringify(dev, null, 2)}\n`);
  writeFileSync(path.join(root, "images/cmux-vm/channels/staging.json"), `${JSON.stringify({ schema: 1, env: "staging", snapshot_id: ID(60) }, null, 2)}\n`);
  writeFileSync(
    path.join(root, "backend/apps/api/wrangler.jsonc"),
    [
      "{",
      '  // the dev Worker',
      '  "env": { "development": {',
      '      "vars": { "ENVIRONMENT": "development", "CLOUD_FREESTYLE_SNAPSHOT": "cmuxnp-dev-vmimg-ci-200-1", "CHIEF_CC_SNAPSHOT": "' + ID(70) + '" },',
      "  } }",
      "}",
      "",
    ].join("\n"),
  );
  return root;
}

function fakeApi(snapshots: Record<string, { slug?: string; displayName?: string } | "missing">) {
  const calls: string[] = [];
  return {
    calls,
    api: () => ({
      async get(id: string) {
        calls.push(`get ${id}`);
        const s = snapshots[id];
        if (!s || s === "missing") throw Object.assign(new Error("Snapshot does not exist"), { status: 404 });
        return { id, ...s };
      },
      async delete(id: string) {
        calls.push(`delete ${id}`);
      },
    }),
  };
}

async function tryDelete(root: string, id: string, snapshots: Parameters<typeof fakeApi>[0] = {}, tip?: string) {
  const fake = fakeApi(snapshots);
  const logs: string[] = [];
  const errors: string[] = [];
  const code = await deleteSnapshot(id, { roots: [[root, ""], ...(tip ? ([[tip, "(branch tip) "]] as const) : [])], snapshots: fake.api, log: (l) => logs.push(l), error: (l) => errors.push(l) });
  return { code, calls: fake.calls, logs, errors: errors.join("\n") };
}

describe("delete_snapshot reference refusal (cleanup.ts --snapshot)", () => {
  const refusedById: Array<[string, number, string]> = [
    ["the dev pointer", 100, "images/cmux-vm/channels/dev.json: snapshot_id"],
    ["dev previous", 99, "images/cmux-vm/channels/dev.json: previous.snapshot_id"],
    ["a prose note", 4, "images/cmux-vm/channels/dev.json: also_kept"],
    ["the team VM pointer", 7, "images/cmux-vm/channels/dev.json: team_vm.snapshot_id"],
    ["dev history", 50, "images/cmux-vm/channels/dev.json: history[0].snapshot_id"],
    ["another channel file", 60, "images/cmux-vm/channels/staging.json: snapshot_id"],
    ["a wrangler.jsonc var", 70, "backend/apps/api/wrangler.jsonc:4 CHIEF_CC_SNAPSHOT"],
  ];
  for (const [label, n, ref] of refusedById) {
    test(`an id in ${label} is refused, named, and never read or deleted`, async () => {
      const r = await tryDelete(fakeRoot(), ID(n), { [ID(n)]: { slug: "cmuxnp-dev-vmimg-free" } });
      expect(r.code).toBe(1);
      expect(r.errors).toContain(ref);
      expect(r.calls).toEqual([]);
    });
  }

  test("a snapshot whose name wrangler.jsonc boots is refused after the read, never deleted", async () => {
    const r = await tryDelete(fakeRoot(), ID(200), { [ID(200)]: { slug: "cmuxnp-dev-vmimg-ci-200-1" } });
    expect(r.code).toBe(1);
    expect(r.errors).toContain("backend/apps/api/wrangler.jsonc:4 CLOUD_FREESTYLE_SNAPSHOT mentions cmuxnp-dev-vmimg-ci-200-1");
    expect(r.calls).toEqual([`get ${ID(200)}`]);
  });

  test("fails closed: a channel file that does not parse refuses every id", async () => {
    const root = fakeRoot();
    writeFileSync(path.join(root, "images/cmux-vm/channels/broken.json"), `{ "snapshot_id": "sh-\\u0030${"0".repeat(31)}", `);
    const r = await tryDelete(root, ID(23), { [ID(23)]: { slug: "cmuxnp-dev-vmimg-free" } });
    expect(r.code).toBe(1);
    expect(r.errors).toContain("images/cmux-vm/channels/broken.json: (file does not parse");
    expect(r.calls).toEqual([]);
  });

  test("an escaped or upper-case id still counts as a reference", async () => {
    const root = fakeRoot();
    const id = ID(24);
    writeFileSync(path.join(root, "images/cmux-vm/channels/escaped.json"), `{ "note": "${id.replace("-", "\\u002d")}", "loud": "${ID(25).toUpperCase()}" }\n`);
    writeFileSync(path.join(root, "backend/apps/api/wrangler.jsonc"), `{ "vars": { "X_SNAPSHOT": "${ID(26).replace("sh", "s\\u0068")}" } }\n`);
    for (const [n, ref] of [[24, "escaped.json: note"], [25, "escaped.json: loud"], [26, "wrangler.jsonc:1 X_SNAPSHOT"]] as const) {
      const r = await tryDelete(root, ID(n), { [ID(n)]: { slug: "cmuxnp-dev-vmimg-free" } });
      expect(r.code).toBe(1);
      expect(r.errors).toContain(ref);
      expect(r.calls).toEqual([]);
    }
  });

  test("a mention JSON.parse drops (a duplicate key) still counts", async () => {
    const root = fakeRoot();
    writeFileSync(path.join(root, "images/cmux-vm/channels/dup.json"), `{ "history": [{ "snapshot_id": "${ID(27)}" }], "history": [] }\n`);
    const r = await tryDelete(root, ID(27), { [ID(27)]: { slug: "cmuxnp-dev-vmimg-free" } });
    expect(r.code).toBe(1);
    expect(r.errors).toContain("images/cmux-vm/channels/dup.json:1 snapshot_id mentions");
    expect(r.calls).toEqual([]);
  });

  test("a dropped duplicate whose id follows an escape (\\n, \\t) still counts", async () => {
    const root = fakeRoot();
    writeFileSync(path.join(root, "images/cmux-vm/channels/esc.json"), `{ "note": "\\n${ID(29)}", "note": "", "x": "\\t${ID(30)}", "x": "" }\n`);
    for (const n of [29, 30]) {
      const r = await tryDelete(root, ID(n), { [ID(n)]: { slug: "cmuxnp-dev-vmimg-free" } });
      expect(r.code).toBe(1);
      expect(r.errors).toContain("images/cmux-vm/channels/esc.json:1 ");
      expect(r.calls).toEqual([]);
    }
  });

  test("a reference only on the branch tip (a channel PR that landed meanwhile) is refused", async () => {
    const tip = fakeRoot();
    writeFileSync(path.join(tip, "images/cmux-vm/channels/staging.json"), `{ "snapshot_id": "${ID(28)}" }\n`);
    const r = await tryDelete(fakeRoot(), ID(28), { [ID(28)]: { slug: "cmuxnp-dev-vmimg-free" } }, tip);
    expect(r.code).toBe(1);
    expect(r.errors).toContain("(branch tip) images/cmux-vm/channels/staging.json: snapshot_id");
    expect(r.calls).toEqual([]);
  });

  test("a name only in a channel file (no id recorded) is refused", async () => {
    const r = await tryDelete(fakeRoot(), ID(98), { [ID(98)]: { slug: "cmuxnp-dev-vmimg-auto4" } });
    expect(r.code).toBe(1);
    expect(r.errors).toContain("images/cmux-vm/channels/dev.json: also_kept mentions cmuxnp-dev-vmimg-auto4");
    expect(r.calls).not.toContain(`delete ${ID(98)}`);
  });

  test("a name that is only a prefix of a referenced name is not a reference", async () => {
    const r = await tryDelete(fakeRoot(), ID(20), { [ID(20)]: { slug: "cmuxnp-dev-vmimg-ci-20", displayName: "cmuxnp-dev-vmimg-ci-20" } });
    expect(r.errors).toBe("");
    expect(r.code).toBe(0);
    expect(r.calls).toEqual([`get ${ID(20)}`, `delete ${ID(20)}`]);
    expect(r.logs.join("\n")).toContain("reference check passed");
  });

  test("a snapshot that is not a cmuxnp-dev-vmimg- image is refused", async () => {
    for (const named of [{ slug: "cmuxnp-stg-vmimg-x" }, { slug: "cmuxnp-dev-vmimg-x", displayName: "chief-cc" }, {}]) {
      const r = await tryDelete(fakeRoot(), ID(21), { [ID(21)]: named });
      expect(r.code).toBe(1);
      expect(r.calls).toEqual([`get ${ID(21)}`]);
    }
  });

  test("an id that is gone already is not an error", async () => {
    const r = await tryDelete(fakeRoot(), ID(22), { [ID(22)]: "missing" });
    expect(r.code).toBe(0);
    expect(r.calls).toEqual([`get ${ID(22)}`]);
  });

  test("a value that is not a snapshot id is refused before anything else", async () => {
    for (const bad of ["", "sh-abc", `${ID(1)} `, "cmuxnp-dev-vmimg-ci-200-1"]) {
      const r = await tryDelete(fakeRoot(), bad);
      expect(r.code).toBe(1);
      expect(r.calls).toEqual([]);
    }
  });

  test("the real channel files protect the serving dev image and every history entry", () => {
    const dev = JSON.parse(readFileSync(path.join(REPO, "images/cmux-vm/channels/dev.json"), "utf8")) as { snapshot_id: string; history: Array<{ snapshot_id: string }> };
    for (const id of [dev.snapshot_id, ...dev.history.map((h) => h.snapshot_id)]) expect(snapshotReferences(REPO, [id]).length).toBeGreaterThan(0);
  });
});

describe("promote-record.ts", () => {
  const candidate = (over: Record<string, unknown> = {}) => ({
    schema: 1,
    env: "dev",
    var: "CLOUD_FREESTYLE_SNAPSHOT",
    snapshot: "cmuxnp-dev-vmimg-ci-300-1",
    snapshot_id: ID(300),
    lock_sha256: "f".repeat(64),
    source_sha: "41c5481957f3",
    run: 300,
    baked_at: "2026-10-26T04:48:20Z",
    bake: "images/cmux-vm/bake.ts --agent-tools (CI run 300)",
    smoke: { result: "PASSED", at: "2026-10-26T04:48:20Z", detail: "smoke.ts --clones 2 (CI run 300): 25 checks passed" },
    ...over,
  });
  const devHistory = (root: string) => (JSON.parse(readFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), "utf8")) as { history: Array<Record<string, unknown>> }).history;

  test("appends the candidate minus schema and env, once", () => {
    const root = fakeRoot();
    expect(recordCandidate(root, candidate(), ID(300), "300")).toEqual({ var: "CLOUD_FREESTYLE_SNAPSHOT", appended: true });
    const { schema: _s, env: _e, ...entry } = candidate();
    expect(devHistory(root).at(-1)).toEqual(entry);
    expect(recordCandidate(root, candidate(), ID(300), "300")).toEqual({ var: "CLOUD_FREESTYLE_SNAPSHOT", appended: false });
    expect(devHistory(root).length).toBe(2);
    expect(() => recordCandidate(root, candidate({ baked_at: "later" }), ID(300), "300")).toThrow(/never edited/);
  });

  test("a team VM candidate records its var", () => {
    const root = fakeRoot();
    expect(recordCandidate(root, candidate({ var: "TEAM_VM_SNAPSHOT", snapshot: "cmuxnp-dev-vmimg-ci-team-300-1" }), ID(300), "300").var).toBe("TEAM_VM_SNAPSHOT");
  });

  test("refuses a dev.json without a history array", () => {
    const root = fakeRoot();
    const file = path.join(root, "images/cmux-vm/channels/dev.json");
    writeFileSync(file, `${JSON.stringify({ ...JSON.parse(readFileSync(file, "utf8")), history: { a: ID(50) } }, null, 2)}\n`);
    const before = readFileSync(file, "utf8");
    expect(() => recordCandidate(root, candidate(), ID(300), "300")).toThrow(/no history array/);
    expect(readFileSync(file, "utf8")).toBe(before);
  });

  const refused: Array<[string, Record<string, unknown>, string, string]> = [
    ["another snapshot", {}, ID(301), "300"],
    ["another run", {}, ID(300), "301"],
    ["a failed smoke", { smoke: { result: "FAILED" } }, ID(300), "300"],
    ["a staging candidate", { env: "staging" }, ID(300), "300"],
    ["a foreign name", { snapshot: "cmuxnp-stg-vmimg-ci-300-1" }, ID(300), "300"],
    ["an unknown var", { var: "CHIEF_CC_SNAPSHOT" }, ID(300), "300"],
    ["a bad run id", {}, ID(300), "300; true"],
  ];
  for (const [label, over, snapshot, run] of refused) {
    test(`refuses ${label} and leaves dev.json alone`, () => {
      const root = fakeRoot();
      const before = readFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), "utf8");
      expect(() => recordCandidate(root, candidate(over), snapshot, run)).toThrow(/refusing|not a/);
      expect(readFileSync(path.join(root, "images/cmux-vm/channels/dev.json"), "utf8")).toBe(before);
    });
  }
});
