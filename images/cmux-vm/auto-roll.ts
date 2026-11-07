#!/usr/bin/env bun
// The Cloud VM image roll (.github/workflows/cloud-vm-image-roll.yml): a feat-cmux-next cmux-tui build or
// image change is pinned, baked and gated with no hand PR, then made production's first boot image by a bot
// commit, and taken back out by one when the production smoke after that commit's deploy is red.
//
//   bun images/cmux-vm/auto-roll.ts plan --event dispatch|build|push [--commit <40-hex>] [--before <sha>]
//       [--dry-run auto|true|false] [--tip <ref>] [--repo <checkout>]
//     Prints what to roll as JSON: roll (true|false), reason, pin (the cmux-tui commit to pin, or ""),
//     dryRun, and the fix commits (sha, merged-at, subject) the roll carries. Reads git and files.cmux.com only.
//     Fails closed (exits non-zero) on a shallow checkout or a pinned commit the checkout lacks: the guard that
//     never rolls an older build needs the pin's history.
//   bun images/cmux-vm/auto-roll.ts approve --candidate <channel-dev.json> --revision <ci-RUN-ATTEMPT>
//       --run <roll run id> --attempt <roll run attempt> [--wrangler <path>] [--lock <path>]
//     Puts the baked, gated image first in production's VM_BOOT_IMAGES and last in staging's, trims the
//     oldest auto-rolled entries, and refuses when the lock no longer hashes to what was baked.
//   bun images/cmux-vm/auto-roll.ts rollback --image <id> [--wrangler <path>]
//     Removes an auto-rolled image from both lists wherever it is, so it can never be first again (when it was
//     first, the entry before it boots again). Prints what it did; never removes a hand-approved image.
//   bun images/cmux-vm/auto-roll.ts settle --kind roll|rollback --image <id> --deploy <result> --product <outcome>
//       --boot-image <id> --deployed-wrangler <path> [--wrangler <tip path>] [--attempt <n>]
//     What cmux-vm.yml's image-roll-settle does after a roll or rollback commit's production deploy and smoke
//     (see settle() below). Prints the decision as JSON; changes nothing.
//
// Every edit rewrites only the two VM_BOOT_IMAGES string values; the rest of wrangler.jsonc keeps its bytes.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const DEFAULT_WRANGLER = path.join(ROOT, "workers/cmux-vm/wrangler.jsonc");
export const DEFAULT_LOCK = path.join(ROOT, "images/cmux-vm/inputs.lock.json");
export const MODE_FILE = path.join(ROOT, "images/cmux-vm/auto-roll.json");

/** Ids this tool writes; only these are ever trimmed or rolled back. */
export const AUTO_PREFIX = "cloud-native-auto-";
/** Auto-rolled entries each list keeps (the newest); older ones leave the list, never a hand-approved one. */
export const KEEP_AUTO = 6;
/** The Worker refuses a longer list and then disables every approved image (src/upstream/live-images.ts). */
export const MAX_ENTRIES = 32;
/** Cloudflare refuses a Worker text binding over 5.1 kB (code 10054), so the whole deploy fails (cmux-vm runs
 * 42361417513 and 42361837374: staging's 26 entries were 6.0 kB). Bytes of the binding's value, the list's JSON. */
export const MAX_BYTES = 5_120;
export const SERVICES = {
  production: ["cloud-platform-production", "ci-product-smoke"],
  staging: ["cloud-platform-dev", "cloud-platform-staging"],
} as const;
/** The paths whose change is a change to what the image carries (the push trigger's paths). */
export const IMAGE_PATHS = ["images/cmux-vm", "web/scripts/cmux-vm-image", ":(exclude)images/cmux-vm/channels"];

export type BootImage = {
  id: string;
  revision: string;
  displayName: string;
  snapshotId: string;
  services: string[];
};
type Env = keyof typeof SERVICES;

// ---- wrangler.jsonc: the VM_BOOT_IMAGES value of one environment ----

const ENV_KEYS: Record<Env, string> = { staging: '"staging": {', production: '"production": {' };

/** The span of `"VM_BOOT_IMAGES": "<json string>"` inside env.<name>, with the decoded list. */
export function locate(text: string, env: Env): { start: number; end: number; images: BootImage[] } {
  const envAt = text.indexOf(ENV_KEYS[env]);
  if (envAt < 0) throw new Error(`wrangler.jsonc has no env ${env}`);
  // The next environment key bounds the search, so staging never reads production's value.
  const nextEnv = env === "staging" ? text.indexOf(ENV_KEYS.production, envAt) : -1;
  const re = /"VM_BOOT_IMAGES": ("(?:[^"\\\n]|\\.)*")/gu;
  re.lastIndex = envAt;
  const match = re.exec(text);
  if (!match || (nextEnv >= 0 && match.index > nextEnv)) throw new Error(`env ${env} has no VM_BOOT_IMAGES`);
  const literal = match[1]!;
  const start = match.index + match[0].length - literal.length;
  const images = JSON.parse(JSON.parse(literal) as string) as BootImage[];
  validate(images, env);
  return { start, end: start + literal.length, images };
}

export function replaceList(text: string, env: Env, images: BootImage[]): string {
  validate(images, env);
  // Only a write is held to the size cap: settle still reads a deployed commit's list from before a trim.
  const bytes = Buffer.byteLength(JSON.stringify(images), "utf8");
  if (bytes > MAX_BYTES) throw new Error(`env ${env} VM_BOOT_IMAGES: ${bytes} bytes, at most ${MAX_BYTES} (Cloudflare's text binding limit)`);
  const { start, end } = locate(text, env);
  return text.slice(0, start) + JSON.stringify(JSON.stringify(images)) + text.slice(end);
}

/** The Worker's schema (src/upstream/live-images.ts, src/api/images.ts): an invalid list disables every image. */
export function validate(images: BootImage[], env: string): void {
  const fail = (why: string) => {
    throw new Error(`env ${env} VM_BOOT_IMAGES: ${why}`);
  };
  if (!Array.isArray(images)) fail("not a list");
  if (images.length > MAX_ENTRIES) fail(`${images.length} entries, at most ${MAX_ENTRIES}`);
  if (new Set(images.map((i) => i.id)).size !== images.length) fail("duplicate ids");
  for (const i of images) {
    const keys = Object.keys(i).sort().join(",");
    if (keys !== "displayName,id,revision,services,snapshotId") fail(`${i.id}: fields ${keys}`);
    if (!/^[a-z][a-z0-9-]*$/u.test(i.id) || i.id.length > 63) fail(`bad id ${i.id}`);
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/u.test(i.revision) || i.revision.length > 64) fail(`${i.id}: bad revision`);
    if (i.displayName.length < 1 || i.displayName.length > 100 || [...i.displayName].some((c) => c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127))
      fail(`${i.id}: bad displayName`);
    if (i.snapshotId.length < 1 || i.snapshotId.length > 256 || i.snapshotId === "." || i.snapshotId === ".." || /[^\x21-\x7e]/u.test(i.snapshotId))
      fail(`${i.id}: bad snapshotId`);
    if (i.services.length < 1 || i.services.length > 32 || i.services.some((s) => !/^[a-z][a-z0-9-]{0,39}$/u.test(s))) fail(`${i.id}: bad services`);
  }
}

/** Drops the oldest auto-rolled entries past KEEP_AUTO; `newestFirst` says which end of the list is newest. */
export function trimAuto(images: BootImage[], newestFirst: boolean): BootImage[] {
  const ordered = newestFirst ? images : [...images].reverse();
  let seen = 0;
  const kept = ordered.filter((i) => !i.id.startsWith(AUTO_PREFIX) || ++seen <= KEEP_AUTO);
  return newestFirst ? kept : kept.reverse();
}

export type Candidate = { snapshot_id: string; lock_sha256: string; run: number; source_sha?: string; smoke?: { detail?: string }; cmux_tui?: { commit?: string } };

/** The approved entry for a baked candidate: production first, staging last (its order is append-only). */
export function approve(text: string, entry: BootImage): { text: string; previousFirst: string } {
  const prod = locate(text, "production").images;
  const staging = locate(text, "staging").images;
  if (prod.some((i) => i.id === entry.id) || staging.some((i) => i.id === entry.id)) throw new Error(`${entry.id} is already approved`);
  const nextProd = trimAuto([{ ...entry, services: [...SERVICES.production] }, ...prod], true);
  const nextStaging = trimAuto([...staging, { ...entry, services: [...SERVICES.staging] }], false);
  let out = replaceList(text, "production", nextProd);
  out = replaceList(out, "staging", nextStaging);
  return { text: out, previousFirst: prod[0]?.id ?? "" };
}

/**
 * Takes a failed auto-rolled image out of both lists, first or not. A failed image a newer roll sits above stays
 * second only until that newer roll is rolled back, and would then boot again with no check; removing it wherever
 * it is means it can never come back.
 */
export function rollback(text: string, id: string): { text: string; rolledBack: boolean; reason: string; nowFirst: string } {
  const prod = locate(text, "production").images;
  const first = prod[0]?.id ?? "";
  if (!id.startsWith(AUTO_PREFIX)) return { text, rolledBack: false, reason: `${id} is not an auto-rolled image`, nowFirst: first };
  const staging = locate(text, "staging").images;
  const inProd = prod.some((i) => i.id === id);
  if (!inProd && !staging.some((i) => i.id === id)) return { text, rolledBack: false, reason: `${id} is in neither list`, nowFirst: first };
  const nextProd = prod.filter((i) => i.id !== id);
  if (inProd && nextProd.length === 0) return { text, rolledBack: false, reason: `${id} is production's only image`, nowFirst: first };
  let out = inProd ? replaceList(text, "production", nextProd) : text;
  if (staging.some((i) => i.id === id)) out = replaceList(out, "staging", staging.filter((i) => i.id !== id));
  const nowFirst = nextProd[0]?.id ?? "";
  if (!nowFirst) return { text: out, rolledBack: true, reason: `${id} removed from staging; production lists no image and boots its pin`, nowFirst };
  return { text: out, rolledBack: true, reason: first === id ? `${id} removed; ${nowFirst} boots again` : `${id} removed; ${nowFirst} stays first`, nowFirst };
}

/**
 * The id carries the run attempt: a re-run of a roll run bakes and gates a new snapshot, a different image, so it
 * gets its own entry rather than colliding with (and being refused as) the first attempt's id. Treating "already
 * approved" as success instead would either drop the re-run's new snapshot or need the same one, which a re-baked
 * candidate never has.
 */
export function rolledImage(candidate: Candidate, revision: string, cmuxTui: string, run: string, attempt: string): BootImage {
  if (!/^sh-[0-9a-f]{32}$/u.test(candidate.snapshot_id)) throw new Error("candidate has no snapshot id");
  if (!/^[0-9a-f]{40}$/u.test(cmuxTui)) throw new Error("no cmux-tui commit");
  if (!/^[0-9]{1,20}$/u.test(run)) throw new Error("bad run id");
  if (!/^[1-9][0-9]{0,3}$/u.test(attempt)) throw new Error("bad run attempt");
  return {
    id: `${AUTO_PREFIX}${cmuxTui.slice(0, 8)}-${run}-${attempt}`,
    revision,
    displayName: `Cloud Native (cmux-tui ${cmuxTui.slice(0, 8)}, image roll ${run}.${attempt})`,
    snapshotId: candidate.snapshot_id,
    services: [],
  };
}

// ---- settle: after a roll or rollback commit's production deploy and product smoke ----

/** Production deploys a rollback gets: its commit's own push deploy, then at most 2 dispatched retries. */
export const ROLLBACK_DEPLOYS = 3;

export type SettleInput = {
  kind: "roll" | "rollback";
  /** The image the roll put first, or the one the rollback took out. */
  image: string;
  /** needs.deploy-production.result: success, failure, cancelled (a manual cancel or a timeout) or skipped. */
  deploy: string;
  /** The product create step's outcome in smoke-production ("" when it did not run). */
  product: string;
  /** The image the product create booted ("" when it did not run). */
  bootImage: string;
  /** Production's first entry in the deployed commit's wrangler.jsonc. */
  deployedFirst: string;
  /** Production's first entry at the feat-cmux-next tip now. */
  tipFirst: string;
  /** Whether the image is in either VM_BOOT_IMAGES list at the feat-cmux-next tip now. */
  tipHas: boolean;
  /** Whether the image is in production's list in the deployed commit. */
  deployedHas: boolean;
  /** Whether the image is in staging's list in the deployed commit. */
  deployedStagingHas: boolean;
  /** Rollback only: which production deploy of the rollback this was, 1 for the rollback commit's own. */
  attempt: number;
};
export type SettleOutcome = "green" | "superseded" | "rollback" | "verified" | "retry" | "rollback_failed";
export type Settle = { outcome: SettleOutcome; reason: string; nextAttempt: number };

/**
 * A roll: green only when the deploy and the product create are green and the create booted this image. Anything
 * else (failed, cancelled, timed out, skipped, another image booted) rolls back while the image is in either list
 * at the tip, first or not: a failed image a newer roll sits above would boot again the moment that newer roll is
 * rolled back. Only an image already gone from both lists (superseded) needs nothing. A cancelled deploy alone
 * proves nothing: the production deploy queue never cancels a running deploy, so a cancel is a person or a
 * timeout, and the image may be live.
 *
 * A rollback: verified when its deploy and product create are green, the deployed production list no longer has
 * the rolled-back image and the create booted the deployed first entry. Otherwise the deploy is retried until ROLLBACK_DEPLOYS, then rollback_failed.
 * A rollback's settle never lands another rollback commit, so a rollback cannot loop.
 */
export function settle(s: SettleInput): Settle {
  const done = (outcome: SettleOutcome, reason: string, nextAttempt = 0): Settle => ({ outcome, reason, nextAttempt });
  const seen = `deploy ${s.deploy || "none"}, product smoke ${s.product || "not run"}, booted ${s.bootImage || "nothing"}`;
  const smokeGreen = s.deploy === "success" && s.product === "success";
  if (s.kind === "roll") {
    if (smokeGreen && s.bootImage === s.image && s.deployedFirst === s.image) return done("green", `${s.image} booted in production (${seen})`);
    if (!s.tipHas) return done("superseded", `${seen}; ${s.image} is already in neither list at the tip (production's first is ${s.tipFirst || "none"})`);
    return done("rollback", `${s.image} is not proven in production (${seen})`);
  }
  if (smokeGreen && !s.deployedHas && s.deployedFirst !== "" && s.bootImage === s.deployedFirst)
    return done("verified", `rollback of ${s.image}: ${s.deployedFirst} boots in production again (${seen})`);
  // Production lists no image (it boots the platform's pin) and the rollback only took the image out of staging:
  // no production create can boot a "first entry", so the deployed lists are the proof. A failed deploy still retries.
  if (s.deploy === "success" && s.deployedFirst === "" && !s.deployedHas && !s.deployedStagingHas)
    return done("verified", `rollback of ${s.image}: gone from both lists in the deployed commit; production lists no image and boots its pin (${seen})`);
  if (s.attempt < ROLLBACK_DEPLOYS) return done("retry", `rollback of ${s.image} not verified on deploy ${s.attempt} of ${ROLLBACK_DEPLOYS} (${seen}); deploying again`, s.attempt + 1);
  return done("rollback_failed", `rollback of ${s.image} not verified after ${ROLLBACK_DEPLOYS} production deploys (${seen}); production may still boot it`);
}

// ---- plan ----

/** The checkout plan reads git in (--repo; this repository by default). */
let gitCwd = ROOT;
const git = (args: string[]) => spawnSync("git", args, { cwd: gitCwd, encoding: "utf8", timeout: 120_000 });
const gitOk = (args: string[]) => git(args).status === 0;
const gitOut = (args: string[]) => {
  const r = git(args);
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr.trim()}`);
  return r.stdout.trim();
};

export type FixCommit = { sha: string; mergedAt: string; subject: string };
const FIX_LIMIT = 100;
const fixCommits = (range: string, paths: string[]): FixCommit[] => {
  const r = git(["log", "--first-parent", `--max-count=${FIX_LIMIT}`, "--format=%H%x1f%cI%x1f%s", range, "--", ...paths]);
  if (r.status !== 0) return [];
  return r.stdout.split("\n").filter(Boolean).map((line) => {
    const [sha, mergedAt, subject] = line.split("\x1f");
    return { sha: sha!, mergedAt: mergedAt!, subject: subject! };
  });
};

export type Plan = { roll: boolean; reason: string; pin: string; cmuxTui: string; dryRun: boolean; fixes: FixCommit[]; fixesTruncated: boolean };

export function modeOf(text: string): "off" | "dry-run" | "live" {
  const mode = (JSON.parse(text) as { mode?: unknown }).mode;
  if (mode === "off" || mode === "dry-run" || mode === "live") return mode;
  throw new Error(`auto-roll.json mode must be off, dry-run or live, not ${String(mode)}`);
}

function pinnedCmuxTui(lockText: string): string {
  const lock = JSON.parse(lockText) as { programs?: Array<{ name: string; version: string }> };
  const version = lock.programs?.find((p) => p.name === "cmux-tui")?.version ?? "";
  if (!/^[0-9a-f]{40}$/u.test(version)) throw new Error("the lock pins no cmux-tui commit");
  return version;
}

async function plan(opts: { event: string; commit: string; before: string; dryRun: string; tip: string; lock: string }): Promise<Plan> {
  const mode = modeOf(readFileSync(MODE_FILE, "utf8"));
  const dryRun = opts.dryRun === "true" ? true : opts.dryRun === "false" ? false : mode !== "live";
  const pinned = pinnedCmuxTui(readFileSync(opts.lock, "utf8"));
  const none = (reason: string): Plan => ({ roll: false, reason, pin: "", cmuxTui: pinned, dryRun, fixes: [], fixesTruncated: false });
  if (mode === "off" && opts.event !== "dispatch") return none("images/cmux-vm/auto-roll.json says off");

  if (opts.event === "push") {
    // An image change landed (the trigger's paths); the cmux-tui pin stays.
    const range = /^[0-9a-f]{40}$/u.test(opts.before) && !/^0+$/u.test(opts.before) ? `${opts.before}..${opts.commit}` : `${opts.commit}~1..${opts.commit}`;
    const fixes = fixCommits(range, IMAGE_PATHS);
    if (fixes.length === 0) return none(`no commit in ${range} changes the image inputs`);
    return { roll: true, reason: `image inputs changed in ${range}`, pin: "", cmuxTui: pinned, dryRun, fixes, fixesTruncated: fixes.length >= FIX_LIMIT };
  }
  if (opts.commit === "") {
    if (opts.event !== "dispatch") return none("no commit");
    return { roll: true, reason: "dispatched: rebake the tip's image inputs with the pinned cmux-tui", pin: "", cmuxTui: pinned, dryRun, fixes: [], fixesTruncated: false };
  }
  if (!/^[0-9a-f]{40}$/u.test(opts.commit)) throw new Error("--commit must be 40 hex");
  const commit = opts.commit;
  // Every ancestry answer below needs real history and the pin: a shallow checkout cuts ancestry at its boundary,
  // so is-ancestor can answer "not on the branch" for a build that is, or "not older" for an older one. Either
  // missing fails the plan instead of deciding.
  if (gitOut(["rev-parse", "--is-shallow-repository"]) !== "false") throw new Error("plan needs full history; the checkout is shallow (fetch-depth: 0)");
  if (!gitOk(["cat-file", "-e", `${pinned}^{commit}`])) throw new Error(`the pinned cmux-tui ${pinned.slice(0, 12)} is not in this checkout; fetch it before planning`);
  // Only a build of the branch itself rolls (the exact head a journey ran on), never a lane branch's.
  if (!gitOk(["merge-base", "--is-ancestor", commit, opts.tip])) return none(`${commit} is not on ${opts.tip}`);
  if (commit === pinned) return none(`cmux-tui ${commit.slice(0, 12)} is already pinned`);
  // Never back: an older build than the pinned one does not roll.
  if (gitOk(["merge-base", "--is-ancestor", commit, pinned])) return none(`${commit.slice(0, 12)} is older than the pinned ${pinned.slice(0, 12)}`);

  // What the build would change in the lock (files.cmux.com only); unchanged binaries roll nothing.
  const pin = spawnSync("bun", [path.join(ROOT, "images/cmux-vm/pin-cmux-tui.ts"), "--commit", commit, "--lock", opts.lock], { encoding: "utf8", timeout: 180_000 });
  if (pin.status !== 0) return none(`cmux-tui ${commit.slice(0, 12)} is not published for the image: ${pin.stderr.trim().split("\n").pop() ?? ""}`);
  if ((JSON.parse(pin.stdout) as { unchanged: boolean }).unchanged) return none(`cmux-tui ${commit.slice(0, 12)} carries the pinned binaries`);

  const base = gitOk(["merge-base", "--is-ancestor", pinned, commit]) ? pinned : gitOut(["merge-base", pinned, commit]);
  const fixes = fixCommits(`${base}..${commit}`, ["cmux-tui"]);
  return {
    roll: true,
    reason: `cmux-tui ${commit.slice(0, 12)} changes the image's cmux-tui (pinned ${pinned.slice(0, 12)})`,
    pin: commit,
    cmuxTui: commit,
    dryRun,
    fixes,
    fixesTruncated: fixes.length >= FIX_LIMIT,
  };
}

// ---- CLI ----

function arg(argv: string[], name: string, fallback?: string): string {
  const i = argv.indexOf(name);
  const value = i >= 0 ? argv[i + 1] : fallback;
  if (value === undefined) throw new Error(`${name} is required`);
  return value;
}

async function main(argv: string[]): Promise<number> {
  const [command, ...rest] = argv;
  const wrangler = arg(rest, "--wrangler", DEFAULT_WRANGLER);
  const lock = arg(rest, "--lock", DEFAULT_LOCK);
  if (command === "plan") {
    gitCwd = path.resolve(arg(rest, "--repo", ROOT));
    const result = await plan({
      event: arg(rest, "--event"),
      commit: arg(rest, "--commit", ""),
      before: arg(rest, "--before", ""),
      dryRun: arg(rest, "--dry-run", "auto"),
      tip: arg(rest, "--tip", "HEAD"),
      lock,
    });
    console.log(JSON.stringify(result, null, 2));
    return 0;
  }
  if (command === "approve") {
    const candidate = JSON.parse(readFileSync(arg(rest, "--candidate"), "utf8")) as Candidate;
    const lockText = readFileSync(lock, "utf8");
    const digest = createHash("sha256").update(lockText).digest("hex");
    if (digest !== candidate.lock_sha256) {
      console.error(`approve: the lock here (${digest.slice(0, 12)}) is not the lock the image was baked from (${candidate.lock_sha256.slice(0, 12)}); the tip moved its image inputs`);
      return 4;
    }
    const entry = rolledImage(candidate, arg(rest, "--revision"), pinnedCmuxTui(lockText), arg(rest, "--run"), arg(rest, "--attempt"));
    const before = readFileSync(wrangler, "utf8");
    const { text, previousFirst } = approve(before, entry);
    writeFileSync(wrangler, text);
    console.log(JSON.stringify({ image: { id: entry.id, revision: entry.revision, snapshotId: entry.snapshotId }, previousFirst }, null, 2));
    return 0;
  }
  if (command === "rollback") {
    const before = readFileSync(wrangler, "utf8");
    const result = rollback(before, arg(rest, "--image"));
    if (result.rolledBack) writeFileSync(wrangler, result.text);
    console.log(JSON.stringify({ rolledBack: result.rolledBack, reason: result.reason, nowFirst: result.nowFirst }, null, 2));
    return 0;
  }
  if (command === "settle") {
    const kind = arg(rest, "--kind");
    if (kind !== "roll" && kind !== "rollback") throw new Error("--kind must be roll or rollback");
    const image = arg(rest, "--image");
    const lists = (file: string) => {
      const text = readFileSync(file, "utf8");
      return { prod: locate(text, "production").images.map((i) => i.id), staging: locate(text, "staging").images.map((i) => i.id) };
    };
    const tip = lists(wrangler);
    const deployed = lists(arg(rest, "--deployed-wrangler"));
    const attempt = Number(arg(rest, "--attempt", "1"));
    if (!Number.isInteger(attempt) || attempt < 1) throw new Error("--attempt must be a positive integer");
    const input: SettleInput = {
      kind,
      image,
      deploy: arg(rest, "--deploy", ""),
      product: arg(rest, "--product", ""),
      bootImage: arg(rest, "--boot-image", ""),
      deployedFirst: deployed.prod[0] ?? "",
      tipFirst: tip.prod[0] ?? "",
      tipHas: tip.prod.includes(image) || tip.staging.includes(image),
      deployedHas: deployed.prod.includes(image),
      deployedStagingHas: deployed.staging.includes(image),
      attempt,
    };
    console.log(JSON.stringify({ ...settle(input), deployedFirst: input.deployedFirst, tipFirst: input.tipFirst }, null, 2));
    return 0;
  }
  console.error("usage: auto-roll.ts plan|approve|rollback|settle ... (see the header)");
  return 2;
}

const isEntryPoint = process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntryPoint) process.exit(await main(process.argv.slice(2)));
