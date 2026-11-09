import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  AUTO_PREFIX,
  KEEP_AUTO,
  MAX_BYTES,
  ROLLBACK_DEPLOYS,
  approve,
  locate,
  modeOf,
  replaceList,
  rollback,
  rolledImage,
  settle,
  type BootImage,
  type SettleInput,
} from "../../images/cmux-vm/auto-roll";
import { runChild, runChildOk } from "./helpers/run-child";

// images/cmux-vm/auto-roll.ts edits the checked-in workers/cmux-vm/wrangler.jsonc; these run on that file with its
// auto-rolled entries taken out, since the live roll keeps adding them and the counts below assume none.
const checkedIn = readFileSync(new URL("../../workers/cmux-vm/wrangler.jsonc", import.meta.url), "utf8");
const handOnly = (text: string, env: "staging" | "production") =>
  replaceList(text, env, locate(text, env).images.filter((i) => !i.id.startsWith(AUTO_PREFIX)));
const wrangler = handOnly(handOnly(checkedIn, "staging"), "production");
const candidate = { snapshot_id: `sh-${"a".repeat(32)}`, lock_sha256: "0".repeat(64), run: 1 };
const tui = "1234567890abcdef1234567890abcdef12345678";
const entry = (run: string, attempt = "1"): BootImage => rolledImage(candidate, `ci-${run}-${attempt}`, tui, run, attempt);

/** The file with every VM_BOOT_IMAGES value cut out, to show nothing else moved. */
const skeleton = (text: string) => text.replace(/"VM_BOOT_IMAGES": "(?:[^"\\\n]|\\.)*"/gu, '"VM_BOOT_IMAGES": ""');

describe("auto-roll approve", () => {
  test("puts the image first in production and last in staging, with each environment's services", () => {
    const before = { prod: locate(wrangler, "production").images, staging: locate(wrangler, "staging").images };
    const { text, previousFirst } = approve(wrangler, entry("100"));
    const prod = locate(text, "production").images;
    const staging = locate(text, "staging").images;
    expect(previousFirst).toBe(before.prod[0]!.id);
    expect(prod[0]).toEqual({ ...entry("100"), services: ["cloud-platform-production", "ci-product-smoke"] });
    expect(prod.slice(1)).toEqual(before.prod);
    expect(staging.at(-1)).toEqual({ ...entry("100"), services: ["cloud-platform-dev", "cloud-platform-staging"] });
    expect(staging.slice(0, -1)).toEqual(before.staging);
    expect(skeleton(text)).toBe(skeleton(wrangler));
    expect(prod[0]!.id).toBe(`${AUTO_PREFIX}12345678-100-1`);
  });

  test("keeps only the newest auto-rolled entries and never trims a hand-approved one", () => {
    let text = wrangler;
    for (let run = 1; run <= KEEP_AUTO + 3; run++) text = approve(text, entry(String(run))).text;
    const prod = locate(text, "production").images;
    const staging = locate(text, "staging").images;
    const autoIds = (list: BootImage[]) => list.filter((i) => i.id.startsWith(AUTO_PREFIX)).map((i) => i.id);
    const newest = Array.from({ length: KEEP_AUTO }, (_, i) => `${AUTO_PREFIX}12345678-${KEEP_AUTO + 3 - i}-1`);
    expect(autoIds(prod)).toEqual(newest);
    expect(autoIds(staging)).toEqual([...newest].reverse());
    const hand = (list: BootImage[]) => list.filter((i) => !i.id.startsWith(AUTO_PREFIX));
    expect(hand(prod)).toEqual(locate(wrangler, "production").images);
    expect(hand(staging)).toEqual(locate(wrangler, "staging").images);
  });

  test("refuses an id that is already approved", () => {
    const { text } = approve(wrangler, entry("7"));
    expect(() => approve(text, entry("7"))).toThrow(/already approved/);
  });

  test("a re-run of the roll run (a new attempt) approves its own image instead of colliding", () => {
    const first = approve(wrangler, entry("9", "1")).text;
    const rerun = approve(first, entry("9", "2"));
    const prod = locate(rerun.text, "production").images;
    expect(prod[0]!.id).toBe(`${AUTO_PREFIX}12345678-9-2`);
    expect(prod[1]!.id).toBe(`${AUTO_PREFIX}12345678-9-1`);
    expect(rerun.previousFirst).toBe(`${AUTO_PREFIX}12345678-9-1`);
  });

  test("refuses a list the Worker would reject (more than 32 entries)", () => {
    const prod = locate(wrangler, "production").images;
    // Short entries, so 32 of them stay under MAX_BYTES and the entry cap is what refuses the 33rd.
    const many = Array.from({ length: 32 }, (_, i) => ({ ...prod[0]!, id: `h-${i}`, displayName: "h", services: ["s"] }));
    const big = wrangler.replace(/("production": \{[\s\S]*?"VM_BOOT_IMAGES": )("(?:[^"\\\n]|\\.)*")/u, (_, head: string) => head + JSON.stringify(JSON.stringify(many)));
    expect(() => approve(big, entry("8"))).toThrow(/at most 32/);
  });

  test("refuses a list over Cloudflare's text binding limit, which fails the whole deploy", () => {
    const staging = locate(wrangler, "staging").images;
    // Long hand-approved names push staging past MAX_BYTES while it stays under 32 entries.
    const name = "x".repeat(100);
    const many = Array.from({ length: 24 }, (_, i) => ({ ...staging[0]!, id: `hand-${i}`, displayName: name }));
    expect(Buffer.byteLength(JSON.stringify(many))).toBeGreaterThan(MAX_BYTES);
    const big = wrangler.replace(/("staging": \{[\s\S]*?"VM_BOOT_IMAGES": )("(?:[^"\\\n]|\\.)*")/u, (_, head: string) => head + JSON.stringify(JSON.stringify(many)));
    expect(() => approve(big, entry("8"))).toThrow(/bytes, at most 5120/);
    // A list deployed before a trim still reads, so settle can roll that deploy back.
    expect(locate(big, "staging").images).toHaveLength(24);
  });

  test("the checked-in lists, plus one more roll, stay under the text binding limit", () => {
    const { text } = approve(checkedIn, entry("9000"));
    for (const env of ["staging", "production"] as const)
      expect(Buffer.byteLength(JSON.stringify(locate(text, env).images))).toBeLessThanOrEqual(MAX_BYTES);
  });
});

describe("auto-roll rollback", () => {
  test("takes the first auto-rolled image out of both lists, so the entry before it boots again", () => {
    const original = locate(wrangler, "production").images[0]!.id;
    const { text } = approve(wrangler, entry("200"));
    const result = rollback(text, entry("200").id);
    expect(result.rolledBack).toBe(true);
    expect(result.nowFirst).toBe(original);
    expect(locate(result.text, "production").images).toEqual(locate(wrangler, "production").images);
    expect(locate(result.text, "staging").images).toEqual(locate(wrangler, "staging").images);
  });

  test("removes a failed image a newer roll sits above, so that roll's own rollback cannot bring it back", () => {
    let text = approve(wrangler, entry("300")).text;
    text = approve(text, entry("301")).text;
    const result = rollback(text, entry("300").id);
    expect(result.rolledBack).toBe(true);
    expect(result.nowFirst).toBe(entry("301").id);
    const ids = (t: string) => [...locate(t, "production").images, ...locate(t, "staging").images].map((i) => i.id);
    expect(ids(result.text)).not.toContain(entry("300").id);
    // The newer roll fails too: its rollback leaves the hand-approved first entry, never the earlier failed image.
    const second = rollback(result.text, entry("301").id);
    expect(second.nowFirst).toBe(locate(wrangler, "production").images[0]!.id);
    expect(locate(second.text, "production").images).toEqual(locate(wrangler, "production").images);
    const gone = rollback(second.text, entry("300").id);
    expect(gone.rolledBack).toBe(false);
    expect(gone.reason).toMatch(/in neither list/);
  });

  test("rolls back an auto image only staging lists while production's list is empty, and production keeps its pin", () => {
    // An image staging lists (approve's staging entry, with staging's services) while production lists none.
    const both = approve(wrangler, entry("400")).text;
    const text = replaceList(both, "production", []);
    const result = rollback(text, entry("400").id);
    expect(result.rolledBack).toBe(true);
    expect(result.nowFirst).toBe("");
    expect(result.reason).toMatch(/boots its pin/);
    expect(locate(result.text, "staging").images.map((i) => i.id)).not.toContain(entry("400").id);
    expect(locate(result.text, "production").images).toEqual([]);
  });

  test("never rolls back a hand-approved image", () => {
    const first = locate(wrangler, "production").images[0]!.id;
    const result = rollback(wrangler, first);
    expect(result.rolledBack).toBe(false);
    expect(result.reason).toMatch(/not an auto-rolled image/);
  });
});

describe("auto-roll inputs", () => {
  test("the checked-in switch is a known mode", () => {
    expect(["off", "dry-run", "live"]).toContain(modeOf(readFileSync(new URL("../../images/cmux-vm/auto-roll.json", import.meta.url), "utf8")));
    expect(() => modeOf('{"mode":"on"}')).toThrow();
  });

  test("a candidate without a snapshot id or a cmux-tui commit makes no entry", () => {
    expect(() => rolledImage({ ...candidate, snapshot_id: "" }, "ci-1-1", tui, "1", "1")).toThrow();
    expect(() => rolledImage(candidate, "ci-1-1", "main", "1", "1")).toThrow();
    expect(() => rolledImage(candidate, "ci-1-1", tui, "1", "0")).toThrow(/attempt/);
  });
});

describe("auto-roll settle", () => {
  const image = entry("500").id;
  const previous = locate(wrangler, "production").images[0]!.id;
  const roll = (over: Partial<SettleInput>): SettleInput => ({
    kind: "roll", image, deploy: "success", product: "success", bootImage: image, deployedFirst: image, tipFirst: image, tipHas: true, deployedHas: true, deployedStagingHas: true, attempt: 1, ...over,
  });
  const back = (over: Partial<SettleInput>): SettleInput => ({
    kind: "rollback", image, deploy: "success", product: "success", bootImage: previous, deployedFirst: previous, tipFirst: previous, tipHas: false, deployedHas: false, deployedStagingHas: false, attempt: 1, ...over,
  });

  test("a roll whose deploy and product create booted the image is green", () => {
    expect(settle(roll({})).outcome).toBe("green");
  });

  test("a cancelled, timed out or failed deploy rolls back while the image is still first at the tip", () => {
    for (const deploy of ["cancelled", "failure", "skipped", ""]) expect(settle(roll({ deploy, product: "" })).outcome).toBe("rollback");
    expect(settle(roll({ product: "failure" })).outcome).toBe("rollback");
    // A green create that booted some other image proves nothing about this one.
    expect(settle(roll({ bootImage: previous })).outcome).toBe("rollback");
  });

  test("a failed roll a newer roll sits above still rolls back; only an image gone from both lists is superseded", () => {
    const newer = entry("501").id;
    expect(settle(roll({ deploy: "cancelled", product: "", tipFirst: newer })).outcome).toBe("rollback");
    expect(settle(roll({ deploy: "failure", product: "", tipFirst: newer, tipHas: true })).outcome).toBe("rollback");
    expect(settle(roll({ deploy: "failure", product: "", tipFirst: previous, tipHas: false })).outcome).toBe("superseded");
  });

  test("a rollback is verified only when the create booted the deployed first entry, not the rolled-back image", () => {
    expect(settle(back({})).outcome).toBe("verified");
    expect(settle(back({ bootImage: image })).outcome).not.toBe("verified");
    expect(settle(back({ deployedFirst: image, bootImage: image, deployedHas: true })).outcome).not.toBe("verified");
    // Still in the deployed list below another first entry: not taken out yet.
    expect(settle(back({ deployedHas: true })).outcome).not.toBe("verified");
    expect(settle(back({ bootImage: "" })).outcome).not.toBe("verified");
  });

  test("an unverified rollback retries its deploy, at most ROLLBACK_DEPLOYS deploys, then is rollback_failed", () => {
    expect(ROLLBACK_DEPLOYS).toBe(3);
    for (let attempt = 1; attempt < ROLLBACK_DEPLOYS; attempt++) {
      expect(settle(back({ deploy: "failure", product: "", attempt }))).toMatchObject({ outcome: "retry", nextAttempt: attempt + 1 });
    }
    expect(settle(back({ deploy: "cancelled", product: "", attempt: ROLLBACK_DEPLOYS })).outcome).toBe("rollback_failed");
  });

  test("a staging-only rollback with no production image is verified by the deployed lists, not a production boot", () => {
    // Production lists nothing (it boots its pin), so no create boots a "first entry".
    const none = { deployedFirst: "", tipFirst: "", bootImage: "", product: "" };
    expect(settle(back(none)).outcome).toBe("verified");
    expect(settle(back(none)).reason).toMatch(/boots its pin/);
    // Still in staging in the deployed commit, or a deploy that did not succeed: not verified.
    expect(settle(back({ ...none, deployedStagingHas: true })).outcome).toBe("retry");
    expect(settle(back({ ...none, deploy: "failure" })).outcome).toBe("retry");
  });

  test("a rollback's settle never asks for another rollback commit", () => {
    for (const deploy of ["success", "failure", "cancelled"])
      for (const attempt of [1, 2, 3, 4]) expect(settle(back({ deploy, product: "failure", attempt })).outcome).not.toBe("rollback");
  });

  test("the CLI reads the deployed and tip first entries from wrangler.jsonc files", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-settle-"));
    try {
      const rolled = approve(wrangler, entry("500")).text;
      writeFileSync(path.join(dir, "deployed.jsonc"), rolled);
      writeFileSync(path.join(dir, "tip.jsonc"), rolled);
      const script = new URL("../../images/cmux-vm/auto-roll.ts", import.meta.url).pathname;
      const run = async (deploy: string) => {
        const r = await runChild("bun", [script, "settle", "--kind", "roll", "--image", image, "--deploy", deploy, "--product", "", "--boot-image", "",
          "--deployed-wrangler", path.join(dir, "deployed.jsonc"), "--wrangler", path.join(dir, "tip.jsonc")]);
        expect(r.status).toBe(0);
        return JSON.parse(r.stdout) as { outcome: string; tipFirst: string; deployedFirst: string };
      };
      expect(await run("cancelled")).toMatchObject({ outcome: "rollback", tipFirst: image, deployedFirst: image });
      writeFileSync(path.join(dir, "tip.jsonc"), rollback(rolled, image).text);
      expect(await run("cancelled")).toMatchObject({ outcome: "superseded", tipFirst: previous });
      // A newer roll on top of this failed one: the image is still listed, so it rolls back.
      writeFileSync(path.join(dir, "tip.jsonc"), approve(rolled, entry("502")).text);
      expect(await run("cancelled")).toMatchObject({ outcome: "rollback", tipFirst: entry("502").id });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// The workflows that run the decisions above: they read settle's outcome and never decide on their own.
describe("auto-roll workflows", () => {
  const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
  type Step = { name?: string; id?: string; if?: string; run?: string; env?: Record<string, string> };
  type Job = { if?: string; permissions?: Record<string, string>; steps: Step[] };
  const load = (name: string) =>
    YAML.parse(readFileSync(new URL(`../../.github/workflows/${name}`, import.meta.url), "utf8")) as {
      on: { workflow_dispatch: { inputs: Record<string, unknown> } };
      jobs: Record<string, Job>;
    };
  const vm = load("cmux-vm.yml");
  const settleJob = vm.jobs["image-roll-settle"]!;
  const stepOf = (job: Job, id: string) => job.steps.find((s) => s.id === id)!;

  test("settle runs after a roll commit, a rollback commit and a rollback's retried deploy", () => {
    expect(settleJob.if).toContain("startsWith(github.event.head_commit.message, 'cmux-vm: image roll')");
    expect(settleJob.if).toContain("inputs.action == 'deploy-production' && inputs.image_rollback != ''");
    for (const input of ["image_rollback", "image_roll_run", "image_rollback_attempt"]) expect(vm.on.workflow_dispatch.inputs).toHaveProperty(input);
  });

  test("settle takes its outcome from auto-roll.ts settle, with no cancelled shortcut", () => {
    const read = stepOf(settleJob, "roll").run!;
    expect(read).toContain("auto-roll.ts settle");
    expect(read).not.toMatch(/cancelled/);
    expect(stepOf(settleJob, "rollback").if).toBe("steps.roll.outputs.outcome == 'rollback'");
    expect(stepOf(settleJob, "push-token").if).toBe("steps.roll.outputs.outcome == 'rollback'");
    const retry = stepOf(settleJob, "retry");
    expect(retry.if).toBe("steps.roll.outputs.outcome == 'retry'");
    expect(retry.run).toContain("-f action=deploy-production");
    expect(retry.run).toContain('-f image_rollback_attempt="$NEXT"');
    expect(settleJob.permissions).toMatchObject({ actions: "write" });
  });

  test("the product smoke boots the first image on a roll, a rollback and a retried rollback deploy, and says which", () => {
    const smoke = vm.jobs["smoke-production"]!;
    const product = stepOf(smoke, "product");
    expect(product.env!["CMUX_VM_SMOKE_IMAGE"]).toContain("!startsWith(github.event.head_commit.message, 'cmux-vm: image roll') && inputs.image_rollback == ''");
    expect((smoke as unknown as { outputs: Record<string, string> }).outputs["boot_image"]).toBe("${{ steps.product.outputs.boot_image }}");
  });

  test("the roll bakes the plain image and hands back its channel-dev.json record", () => {
    const roll = load("cloud-vm-image-roll.yml") as unknown as { jobs: { bake: { with: Record<string, unknown> } } };
    expect(roll.jobs.bake.with).toMatchObject({ mode: "bake", keep_snapshot: true, agent_tools: true, roll: true });
    expect(roll.jobs.bake.with).not.toHaveProperty("native_receiver");
    const bake = load("cloud-vm-image-bake.yml");
    expect(stepOf(bake.jobs["bake"]!, "roll_candidate").run).toContain('"$OUT_DIR/channel-dev.json"');
  });

  test("a roll's image id carries the run attempt", () => {
    const roll = load("cloud-vm-image-roll.yml");
    const promote = roll.jobs["promote"]!;
    expect(stepOf(promote, "message").run).toContain('image="cloud-native-auto-${tui:0:8}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"');
    expect(stepOf(promote, "push").run).toContain('--attempt "$GITHUB_RUN_ATTEMPT"');
  });
});

// The shell steps around the decisions, run for real against local git remotes (file://).
describe("auto-roll scripts", () => {
  const repoRoot = new URL("../../", import.meta.url).pathname;
  const gitEnv = { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.com", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.com" };
  const git = (cwd: string, ...args: string[]) => runChildOk("git", args, { cwd, env: gitEnv });
  const withDir = async (body: (dir: string) => Promise<void>) => {
    const dir = mkdtempSync(path.join(tmpdir(), "auto-roll-script-"));
    try {
      await body(dir);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };

  test("the record script writes the first record, deep-merges rollback deploys and never lets a null erase one", () =>
    withDir(async (dir) => {
      await git(dir, "init", "-q", "--bare", "remote.git");
      const record = async (patch: object) =>
        runChildOk("bash", [path.join(repoRoot, "images/cmux-vm/image-roll-record.sh"), "77"], {
          cwd: dir,
          input: JSON.stringify(patch),
          env: { ...gitEnv, TOKEN: "unused", GITHUB_REPOSITORY: "remote", GITHUB_SERVER_URL: `file://${dir}`, CMUX_IMAGE_ROLL_BRANCH: "cloud-image-rolls" },
        });
      const read = async () => JSON.parse((await git(path.join(dir, "remote.git"), "show", "cloud-image-rolls:rolls/77.json")).stdout) as Record<string, unknown>;
      // No record yet: the patch is the record.
      await record({ schema: 1, gate: { result: "passed" } });
      expect(await read()).toEqual({ schema: 1, gate: { result: "passed" } });
      await record({ rollback: { result: "pushed", commit: "abc" } });
      await record({ rollback: { result: "retrying", deploys: { "1": { deploy: "failure" } } } });
      await record({ rollback: { result: "verified", deploys: { "2": { deploy: "success" } } } });
      // A re-run of the roll's settle (now superseded) patches rollback: null.
      await record({ production: { superseded: true }, rollback: null });
      expect(await read()).toEqual({
        schema: 1,
        gate: { result: "passed" },
        production: { superseded: true },
        rollback: { result: "verified", commit: "abc", deploys: { "1": { deploy: "failure" }, "2": { deploy: "success" } } },
      });
    }), 60_000);

  test("the push script names the image with the workflow run attempt, not its own push retry counter", () =>
    withDir(async (dir) => {
      const src = path.join(dir, "src");
      for (const file of ["images/cmux-vm/auto-roll.ts", "images/cmux-vm/auto-roll.json", "images/cmux-vm/inputs.lock.json", "images/cmux-vm/image-roll-push.sh", "workers/cmux-vm/wrangler.jsonc"]) {
        mkdirSync(path.dirname(path.join(src, file)), { recursive: true });
        copyFileSync(path.join(repoRoot, file), path.join(src, file));
      }
      await git(dir, "init", "-q", "--bare", "remote.git");
      await git(dir, "init", "-q", "-b", "feat-cmux-next", src);
      await git(src, "add", ".");
      await git(src, "commit", "-q", "-m", "base");
      await git(src, "remote", "add", "origin", path.join(dir, "remote.git"));
      await git(src, "push", "-q", "origin", "feat-cmux-next");
      const lock = readFileSync(path.join(src, "images/cmux-vm/inputs.lock.json"));
      const temp = path.join(dir, "runner-temp");
      mkdirSync(temp);
      writeFileSync(path.join(temp, "candidate.json"), JSON.stringify({ ...candidate, lock_sha256: createHash("sha256").update(lock).digest("hex") }));
      writeFileSync(path.join(temp, "message.txt"), "cmux-vm: image roll test\n");
      const out = await runChildOk(
        "bash",
        ["images/cmux-vm/image-roll-push.sh", "roll", "--candidate", path.join(temp, "candidate.json"), "--revision", "ci-4242-2", "--run", "4242",
          "--attempt", "2", "--message-file", path.join(temp, "message.txt"), "--dry-run"],
        { cwd: src, env: { ...gitEnv, RUNNER_TEMP: temp, GITHUB_OUTPUT: path.join(temp, "output") } },
      );
      expect(out.stdout.trim().split("\n").at(-1)).toMatch(/^dry-run [0-9a-f]{40}/);
      const approved = JSON.parse(readFileSync(path.join(temp, "approve.json"), "utf8")) as { image: { id: string } };
      expect(approved.image.id).toMatch(/^cloud-native-auto-[0-9a-f]{8}-4242-2$/);
    }), 60_000);

  test("plan fails closed on a shallow checkout or a pin it lacks, and still refuses a build older than the pin", () =>
    withDir(async (dir) => {
      const full = path.join(dir, "full");
      await git(dir, "init", "-q", "-b", "feat-cmux-next", full);
      const commitOf = async (msg: string) => {
        await git(full, "commit", "-q", "--allow-empty", "-m", msg);
        return (await git(full, "rev-parse", "HEAD")).stdout.trim();
      };
      const older = await commitOf("older");
      const pinned = await commitOf("pinned");
      const tip = await commitOf("tip");
      const lock = path.join(dir, "lock.json");
      writeFileSync(lock, JSON.stringify({ programs: [{ name: "cmux-tui", version: pinned }] }));
      const script = path.join(repoRoot, "images/cmux-vm/auto-roll.ts");
      const plan = (repo: string, commit: string) => runChild("bun", [script, "plan", "--event", "build", "--commit", commit, "--tip", "HEAD", "--lock", lock, "--repo", repo]);

      const ok = await plan(full, older);
      expect(ok.status).toBe(0);
      const decided = JSON.parse(ok.stdout) as { roll: boolean; reason: string };
      expect(decided.roll).toBe(false);
      expect(decided.reason).toMatch(/older than the pinned/);

      // A depth-1 clone of the tip: the old build is unreachable, the guard cannot decide, the plan errors.
      const shallow = path.join(dir, "shallow");
      await git(dir, "clone", "-q", "--depth", "1", "--branch", "feat-cmux-next", `file://${full}`, shallow);
      const cut = await plan(shallow, tip);
      expect(cut.status).not.toBe(0);
      expect(cut.stderr).toMatch(/shallow/);
      // A build outside the shallow history: the branch check would answer "not on the branch" (roll: false) from
      // the cut alone, so the shallow refusal has to come first (review of #37409, F1).
      const beyond = await plan(shallow, older);
      expect(beyond.status).not.toBe(0);
      expect(beyond.stderr).toMatch(/shallow/);

      // Full history without the pinned commit (a pin off the branch that was never fetched).
      writeFileSync(lock, JSON.stringify({ programs: [{ name: "cmux-tui", version: "f".repeat(40) }] }));
      const missing = await plan(full, tip);
      expect(missing.status).not.toBe(0);
      expect(missing.stderr).toMatch(/not in this checkout/);
    }), 60_000);

  test("the plan job checks out full history and fails on a pin it cannot fetch", () => {
    const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
    type Step = { id?: string; run?: string; with?: Record<string, unknown> };
    const roll = YAML.parse(readFileSync(new URL("../../.github/workflows/cloud-vm-image-roll.yml", import.meta.url), "utf8")) as { jobs: Record<string, { steps: Step[] }> };
    const steps = roll.jobs["plan"]!.steps;
    expect(steps[0]!.with).toMatchObject({ "fetch-depth": 0, filter: "blob:none" });
    const run = steps.find((s) => s.id === "plan")!.run!;
    expect(run).toContain('git fetch -q --filter=blob:none origin "$pinned"; fi');
    expect(run).not.toMatch(/--depth 1/);
  });
});

// The roll calls cloud-vm-image-bake.yml as a reusable workflow; its Freestyle key and UI test login are
// repository secrets, which reach a called workflow only when passed.
describe("auto-roll bake secrets", () => {
  const { YAML } = (globalThis as unknown as { Bun: { YAML: { parse(text: string): unknown } } }).Bun;
  type Workflow = {
    on: { workflow_call: { inputs: Record<string, unknown>; secrets: Record<string, unknown> } };
    jobs: Record<string, { secrets?: Record<string, string>; steps: Array<{ name?: string; run?: string }> }>;
  };
  const load = (name: string) => YAML.parse(readFileSync(new URL(`../../.github/workflows/${name}`, import.meta.url), "utf8")) as Workflow;
  const NAMES = ["FREESTYLE_API_KEY", "CMUX_UITEST_STACK_EMAIL", "CMUX_UITEST_STACK_PASSWORD"];

  test("the bake declares exactly the three secrets, all optional, and the roll passes exactly those", () => {
    const call = load("cloud-vm-image-bake.yml").on.workflow_call;
    expect(Object.keys(call.secrets).sort()).toEqual([...NAMES].sort());
    for (const name of NAMES) expect(call.secrets[name]).toEqual({ required: false });
    const bake = load("cloud-vm-image-roll.yml").jobs["bake"]!;
    expect(bake.secrets).toEqual(Object.fromEntries(NAMES.map((n) => [n, `\${{ secrets.${n} }}`])));
  });

  test("prod-copy still refuses when called: workflow_call has no dev_snapshot, and the input check rejects an empty one", async () => {
    const bakeWorkflow = load("cloud-vm-image-bake.yml");
    expect(bakeWorkflow.on.workflow_call.inputs).not.toHaveProperty("dev_snapshot");
    const check = bakeWorkflow.jobs["bake"]!.steps.find((s) => s.name === "Check the production copy inputs")!;
    const r = await runChild("bash", ["-c", check.run!], {
      env: { PATH: process.env["PATH"], GITHUB_REF: "refs/heads/feat-cmux-next", DEV_SNAPSHOT: "", FLAG_INPUTS: "", HAS_KEY: "yes", HAS_EMAIL: "yes", HAS_PASSWORD: "yes" },
    });
    expect(r.status).toBe(1);
    expect(r.stdout).toContain("dev_snapshot must be the dev image's snapshot id");
  });
});
