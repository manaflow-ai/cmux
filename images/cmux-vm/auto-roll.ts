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
//       --run <roll run id> --attempt <roll run attempt> [--wrangler <path>] [--lock <path>] [--platform-wrangler <path>]
//     Puts the baked, gated image first in production's VM_BOOT_IMAGES and last in staging's, trims the
//     oldest auto-rolled entries, and refuses when the lock no longer hashes to what was baked. The entry carries
//     the candidate's large image (`large`) only when auto-roll.json says large_image: true and the Worker beside
//     that wrangler.jsonc reads the field (workerReadsLarge).
//     With that switch on, a list over the binding limit drops its oldest rolls, each named on stderr and in the
//     printed JSON (`dropped`); with it off such a list is refused, as before.
//   bun images/cmux-vm/auto-roll.ts lists [--wrangler <path>] [--lock <path>]
//     Every cmux-vm.yml check: both lists parse and fit the binding limit, the lock parses, and an entry
//     carries `large` only beside a Worker that reads it. Exits 1 otherwise.
//   bun images/cmux-vm/auto-roll.ts notes --candidate <channel-dev.json> [--approve <approve.json>] --result <r>
//     The lines the promote job puts in its summary: rolls the byte trim dropped, and a large snapshot that
//     was baked and kept but is not published (rollNotes).
//     --platform-wrangler (cmux-platform's root wrangler.jsonc) names its CLOUD_VM_API_IMAGE pins, which are never
//     trimmed, by count or by bytes.
//   bun images/cmux-vm/auto-roll.ts behind --pin <40-hex> [--lock <path>] [--repo <checkout>]
//     Exits 3 when the pin is older than the cmux-tui the lock pins (a newer roll landed while this one baked),
//     0 when it may roll; fails closed on a shallow checkout or a commit it lacks. image-roll-push.sh asks before
//     it writes the pin onto the tip.
//   bun images/cmux-vm/auto-roll.ts rollback --image <id> [--wrangler <path>] [--platform-wrangler <path>]
//     (refuses an image cmux-platform pins)
//     Removes an auto-rolled image from both lists wherever it is, so it can never be first again (when it was
//     first, the entry before it boots again). Prints what it did; never removes a hand-approved image.
//   bun images/cmux-vm/auto-roll.ts settle --kind roll|rollback --image <id> --deploy <result> --product <outcome>
//       --boot-image <id> --deployed-wrangler <path> [--wrangler <tip path>] [--attempt <n>]
//     What cmux-vm.yml's image-roll-settle does after a roll or rollback commit's production deploy and smoke
//     (see settle() below). Prints the decision as JSON; changes nothing.
//   bun images/cmux-vm/auto-roll.ts check [--max-behind <n>] [--wrangler <path>]
//     The detector for a stale boot image: exits 1 when an environment's boot entry (production's first, staging's
//     last: BOOT_ENTRY) trails production's newest roll by more than n rolls (default MAX_ROLLS_BEHIND).
//
// Every edit rewrites only the two VM_BOOT_IMAGES string values; the rest of wrangler.jsonc keeps its bytes.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const DEFAULT_WRANGLER = path.join(ROOT, "workers/cmux-vm/wrangler.jsonc");
export const DEFAULT_LOCK = path.join(ROOT, "images/cmux-vm/inputs.lock.json");
export const MODE_FILE = path.join(ROOT, "images/cmux-vm/auto-roll.json");

/** Ids this tool writes; only these are ever trimmed or rolled back. */
export const AUTO_PREFIX = "cloud-native-auto-";
/** Auto-rolled entries each list keeps (the newest); older ones leave the list, never a hand-approved one. */
export const KEEP_AUTO = 6;
/**
 * The fewest auto-rolled entries the byte trim (trimToFit) leaves: the one that boots, the one a rollback of it boots
 * again, and one more for a rollback already in flight (MAX_ROLLS_BEHIND). A list that needs fewer to fit is refused.
 */
export const MIN_AUTO = 3;
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
  /** The image's inputs key (bake.ts bakeInputsSha256): absent on entries from before it and on bakes it does not cover. */
  inputs_sha256?: string;
  /** This revision's large image, published with the revision and never added, removed or replaced afterwards. */
  large?: LargeImage;
};
/**
 * A second snapshot of the same bake, taken after its builder was grown to this size (web/scripts/cmux-vm-image/
 * large-image.ts). The Worker boots it for a create that names the image and asks for exactly this size, so no resize
 * follows the create. Its fields and units are the Worker's (workers/cmux-vm/src/upstream/live-images.ts `Large`).
 */
export type LargeImage = { snapshotId: string; vcpus: number; memoryMib: number; diskMib: number };
/**
 * The sizes the Worker accepts on `large` (its `Large` schema, the sizes a create may ask for), mirrored here: the
 * Worker drops a `large` outside them and then boots the small image and resizes, so the roll refuses to write one.
 * Change them only together with that schema.
 */
export const LARGE_BOUNDS = { vcpus: [2, 32], memoryMib: [4096, 65536], diskMib: [16384, 131072] } as const;
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

/** What a write knows about the Worker that will be deployed with the list. */
export type WriteOptions = {
  /** workerReadsLarge()'s answer for the Worker beside the wrangler.jsonc being written. Absent means no. */
  workerReadsLarge?: boolean;
};

export function replaceList(text: string, env: Env, images: BootImage[], options: WriteOptions = {}): string {
  validate(images, env);
  // Only a write is held to the size cap: settle still reads a deployed commit's list from before a trim.
  const bytes = Buffer.byteLength(JSON.stringify(images), "utf8");
  if (bytes > MAX_BYTES) throw new Error(`env ${env} VM_BOOT_IMAGES: ${bytes} bytes, at most ${MAX_BYTES} (Cloudflare's text binding limit)`);
  const { start, end, images: current } = locate(text, env);
  const problem = largeWriteProblem(current, images, options.workerReadsLarge === true);
  if (problem) throw new Error(`env ${env} VM_BOOT_IMAGES: ${problem}`);
  return text.slice(0, start) + JSON.stringify(JSON.stringify(images)) + text.slice(end);
}

const sameLarge = (a: LargeImage | undefined, b: LargeImage | undefined): boolean =>
  a === undefined || b === undefined
    ? a === b
    : a.snapshotId === b.snapshotId && a.vcpus === b.vcpus && a.memoryMib === b.memoryMib && a.diskMib === b.diskMib;

/**
 * The two rules a write of `large` is held to; "" when `next` keeps both.
 *
 * A published revision's `large` never changes: the Worker journals the snapshot a create's first attempt booted, and
 * a retry of that create depends on the entry still naming it. So an entry that stays (same id and revision) keeps its
 * `large`, or its lack of one, exactly; a revision leaves the list only whole (rollback, trim).
 *
 * A newly listed revision carries `large` only when the Worker deployed with the list reads the field: a Worker from
 * before it decodes entries with `onExcessProperty: "error"`, so one entry with `large` makes the whole list invalid
 * and disables every approved image. A list that already has one (it was published beside a Worker that reads it) is
 * rewritten without asking, so a rollback is never held up by this.
 */
function largeWriteProblem(current: BootImage[], next: BootImage[], workerReadsLarge: boolean): string {
  const published = new Map(current.map((i) => [i.id, i]));
  for (const i of next) {
    const was = published.get(i.id);
    if (was !== undefined && was.revision === i.revision) {
      if (!sameLarge(was.large, i.large)) return `${i.id}: revision ${i.revision} is already published; its large image is never added, removed or replaced afterwards`;
    } else if (i.large !== undefined && !workerReadsLarge) {
      return `${i.id}: carries a large image, and a Worker that does not read \`large\` would disable every image`;
    }
  }
  return "";
}

/**
 * Whether the Worker whose source sits beside a wrangler.jsonc (`workerDir`, workers/cmux-vm) reads `large`: asked of
 * its own list parser, with a list of one entry that carries one. True only when that parser accepts the list and
 * hands the large image back. A Worker from before the field (the whole list is invalid), one that drops it, a
 * checkout without the Worker's source (cmux-platform's sparse one) or without its dependencies installed, and a
 * child that fails, hangs or prints anything else are all no.
 */
export async function workerReadsLarge(workerDir = path.dirname(DEFAULT_WRANGLER)): Promise<boolean> {
  // The Worker's parser and what it imports (effect, from its node_modules) are third-party code to the roll, and
  // approve runs in the step that holds the push tokens. So the question is asked in a child that gets none of this
  // process's environment but probeEnv, and anything but a clean yes on its last line is a no.
  const child = spawnSync(process.execPath, [fileURLToPath(import.meta.url), "worker-reads-large", "--worker", workerDir], {
    env: probeEnv() as NodeJS.ProcessEnv,
    encoding: "utf8",
    timeout: 120_000,
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (child.error || child.status !== 0) return false;
  try {
    const last = child.stdout.trim().split("\n").pop() ?? "";
    return (JSON.parse(last) as { reads?: unknown }).reads === true;
  } catch {
    return false;
  }
}

/** What the child that loads the Worker's parser needs to find and run bun, and nothing else of the caller's. */
const PROBE_ENV = ["PATH", "HOME", "TMPDIR", "LANG"];
export function probeEnv(env: NodeJS.ProcessEnv = process.env): Record<string, string> {
  return Object.fromEntries(PROBE_ENV.flatMap((name) => (env[name] === undefined ? [] : [[name, env[name]]])));
}

/** workerReadsLarge's child: loads the parser in this process. Only ever run with probeEnv. */
async function loadedWorkerReadsLarge(workerDir: string): Promise<boolean> {
  const large: LargeImage = { snapshotId: "sh-probe-large", vcpus: 4, memoryMib: 16384, diskMib: 65536 };
  const probe = [{ id: "probe", revision: "r1", displayName: "Probe", snapshotId: "sh-probe", services: ["probe"], large }];
  try {
    const source = pathToFileURL(path.join(workerDir, "src/upstream/live-images.ts")).href;
    const worker = (await import(source)) as { parseVmImages?: (raw: string) => { ok?: boolean; images?: ReadonlyArray<{ large?: LargeImage }> } };
    const parsed = worker.parseVmImages?.(JSON.stringify(probe));
    return parsed?.ok === true && sameLarge(parsed.images?.[0]?.large, large);
  } catch {
    return false;
  }
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
    const keys = Object.keys(i).sort();
    if (REQUIRED_KEYS.some((k) => !keys.includes(k)) || keys.some((k) => !REQUIRED_KEYS.includes(k) && !OPTIONAL_KEYS.includes(k))) fail(`${i.id}: fields ${keys.join(",")}`);
    if (i.inputs_sha256 !== undefined && !SHA256.test(i.inputs_sha256)) fail(`${i.id}: bad inputs_sha256`);
    const large = keys.includes("large") ? largeProblem(i.large, i.snapshotId) : "";
    if (large) fail(`${i.id}: bad large (${large})`);
    if (!/^[a-z][a-z0-9-]*$/u.test(i.id) || i.id.length > 63) fail(`bad id ${i.id}`);
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/u.test(i.revision) || i.revision.length > 64) fail(`${i.id}: bad revision`);
    if (i.displayName.length < 1 || i.displayName.length > 100 || [...i.displayName].some((c) => c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127))
      fail(`${i.id}: bad displayName`);
    if (i.snapshotId.length < 1 || i.snapshotId.length > 256 || i.snapshotId === "." || i.snapshotId === ".." || /[^\x21-\x7e]/u.test(i.snapshotId))
      fail(`${i.id}: bad snapshotId`);
    if (i.services.length < 1 || i.services.length > 32 || i.services.some((s) => !/^[a-z][a-z0-9-]{0,39}$/u.test(s))) fail(`${i.id}: bad services`);
  }
}

const SHA256 = /^[0-9a-f]{64}$/u;
const REQUIRED_KEYS = ["displayName", "id", "revision", "services", "snapshotId"];
const OPTIONAL_KEYS = ["inputs_sha256", "large"];

const snapshotIdOk = (value: unknown): value is string =>
  typeof value === "string" && value.length >= 1 && value.length <= 256 && value !== "." && value !== ".." && !/[^\x21-\x7e]/u.test(value);

/**
 * Why the Worker would drop this `large` ("" when it would keep it): its `Large` schema refuses unknown fields and
 * sizes outside LARGE_BOUNDS, and a large snapshot that is the entry's own is not one.
 */
function largeProblem(large: unknown, ownSnapshotId: string): string {
  if (typeof large !== "object" || large === null || Array.isArray(large)) return "not an object";
  const value = large as Record<string, unknown>;
  const keys = Object.keys(value).sort().join(",");
  if (keys !== "diskMib,memoryMib,snapshotId,vcpus") return `fields ${keys}`;
  if (!snapshotIdOk(value["snapshotId"])) return "bad snapshotId";
  if (value["snapshotId"] === ownSnapshotId) return "the entry's own snapshot";
  for (const axis of ["vcpus", "memoryMib", "diskMib"] as const) {
    const [min, max] = LARGE_BOUNDS[axis];
    const n = value[axis];
    if (typeof n !== "number" || !Number.isInteger(n) || n < min || n > max) return `${axis} must be a whole number from ${min} to ${max}`;
  }
  return "";
}

/** Drops the oldest auto-rolled entries past KEEP_AUTO; `newestFirst` says which end of the list is newest. */
export function trimAuto(images: BootImage[], newestFirst: boolean, keep: readonly string[] = []): BootImage[] {
  const ordered = newestFirst ? images : [...images].reverse();
  let seen = 0;
  // An image cmux-platform pins (platformPins) is never trimmed and does not count toward KEEP_AUTO.
  const kept = ordered.filter((i) => !i.id.startsWith(AUTO_PREFIX) || keep.includes(i.id) || ++seen <= KEEP_AUTO);
  return newestFirst ? kept : kept.reverse();
}

/**
 * While the list is over the binding limit, drops the oldest auto-rolled entry, never below MIN_AUTO and never a
 * hand-approved one. A large image is 105 bytes on its entry: staging's 12 hand-approved entries leave room for 6
 * rolls without it (4,915 bytes) and 5 with it (6 would be 5,545), so staging keeps 5 once every roll carries one,
 * and production still keeps KEEP_AUTO (4,983). A dropped revision leaves whole, as trimAuto's do: a create that
 * names it afterwards is refused as withdrawn, and machines already running on it are not touched. A list still over
 * the limit at MIN_AUTO is returned as it is, for replaceList to refuse. Every entry it drops is returned with the
 * reason, for approve to print: nothing leaves a list unnamed. Only approve with the large switch on calls it; with
 * the switch off a list over the limit is the refused roll it always was.
 */
export function trimToFit(images: BootImage[], newestFirst: boolean, keep: readonly string[] = []): { images: BootImage[]; dropped: { image: BootImage; why: string }[] } {
  let kept = images;
  const dropped: { image: BootImage; why: string }[] = [];
  for (;;) {
    const bytes = Buffer.byteLength(JSON.stringify(kept), "utf8");
    if (bytes <= MAX_BYTES) break;
    // An image cmux-platform pins (platformPins) is never dropped and does not count toward MIN_AUTO.
    const autoAt = kept.flatMap((i, at) => (i.id.startsWith(AUTO_PREFIX) && !keep.includes(i.id) ? [at] : []));
    if (autoAt.length <= MIN_AUTO) break;
    const oldest = newestFirst ? autoAt[autoAt.length - 1]! : autoAt[0]!;
    dropped.push({ image: kept[oldest]!, why: `the list was ${bytes} bytes with it, over the ${MAX_BYTES}-byte binding limit, and it was the oldest of ${autoAt.length} rolls` });
    kept = kept.filter((_, at) => at !== oldest);
  }
  return { images: kept, dropped };
}

/** A roll the byte trim took out of a list. */
export type Dropped = { env: Env; id: string; revision: string; why: string };

/** The candidate's `large` member (cloud-vm-image-bake.yml writes it once large-smoke.ts passed on that snapshot). */
export type CandidateLarge = { snapshot?: string; snapshot_id?: string; size?: { vcpu?: number; mem_gib?: number; disk_gib?: number }; smoke?: { result?: string } };
export type Candidate = {
  snapshot_id: string;
  lock_sha256: string;
  run: number;
  source_sha?: string;
  smoke?: { detail?: string };
  cmux_tui?: { commit?: string };
  inputs_sha256?: string;
  large?: CandidateLarge;
};

/**
 * The entry's `large` for a candidate's large image, or why it has none. Only a smoked large image whose snapshot is
 * a provider snapshot id of its own and whose size the Worker accepts is published; anything else leaves the entry
 * as it is without one (the large image is never a gate on the roll).
 */
export function candidateLarge(candidate: Candidate): { large?: LargeImage; skipped?: string } {
  const from: unknown = candidate.large;
  if (from === undefined) return { skipped: "the candidate records no large image" };
  if (typeof from !== "object" || from === null) return { skipped: "the candidate's large member is not an object" };
  const { snapshot_id: snapshotId, size, smoke } = from as CandidateLarge;
  if (smoke?.result !== "PASSED") return { skipped: "the large image's smoke did not pass" };
  if (typeof snapshotId !== "string" || !/^sh-[0-9a-f]{32}$/u.test(snapshotId)) return { skipped: "the large image has no snapshot id" };
  const gib = (n: unknown) => (typeof n === "number" ? n * 1024 : Number.NaN);
  const large: LargeImage = { snapshotId, vcpus: typeof size?.vcpu === "number" ? size.vcpu : Number.NaN, memoryMib: gib(size?.mem_gib), diskMib: gib(size?.disk_gib) };
  const problem = largeProblem(large, candidate.snapshot_id);
  return problem ? { skipped: `the large image is one the Worker would drop: ${problem}` } : { large };
}

/**
 * cmux-platform's fallback image (fallback-image.json): what its CLOUD_VM_API_IMAGE pin names in every environment, the
 * image a create boots before that isolate has read cmux-vm's list, and the image a create that recorded the pin boots
 * after. It must stay listed (a recorded pin the list no longer names fails as cloud.provider.image_withdrawn) and must
 * connect and update itself on the current channel. An auto-rolled entry leaves the lists within KEEP_AUTO rolls, and
 * the newest hand-approved one was cloud-native-bd31f93-rd022 (11-07), whose cmux-host ran the session host binary as the
 * relay ticket command (#37770) and whose updater refuses the channel's machine/ URLs (#42308): a machine booted from it
 * never connects (cmuxterm-hq probe cloud-chat-replies-staging, 2026-11-17T14:03:17Z). So every roll writes this entry
 * into both lists when it is missing, under a hand-approved id that trimAuto and rollback never take out. Moving the
 * fallback: a newer smoked roll's entry here (a new id), then cmux-platform's pin once a roll has listed it.
 */
export const FALLBACK_FILE = path.join(ROOT, "images/cmux-vm/fallback-image.json");

export function fallbackImage(file = FALLBACK_FILE): Omit<BootImage, "services"> {
  const fallback = JSON.parse(readFileSync(file, "utf8")) as Omit<BootImage, "services">;
  if (fallback.id.startsWith(AUTO_PREFIX)) throw new Error(`${fallback.id}: the fallback needs a hand-approved id, never ${AUTO_PREFIX}*`);
  validate([{ ...fallback, services: [...SERVICES.production] }], "fallback");
  return fallback;
}

/**
 * `images` with the fallback entry, when it is missing, where the hand-approved entries meet the auto-rolled ones: after
 * production's rolls (it boots its first entry) and before staging's (it boots its last), so no environment boots it.
 */
export function withFallback(images: BootImage[], env: Env, fallback = fallbackImage()): BootImage[] {
  if (images.some((i) => i.id === fallback.id)) return images;
  const auto = (i: BootImage) => i.id.startsWith(AUTO_PREFIX);
  const found = env === "production" ? images.findIndex((i) => !auto(i)) : images.findIndex(auto);
  const at = found < 0 ? images.length : found;
  return [...images.slice(0, at), { ...fallback, services: [...SERVICES[env]] }, ...images.slice(at)];
}

/**
 * cmux-platform's CLOUD_VM_API_IMAGE pins, from its wrangler.jsonc text (every environment, each id once): the image a
 * create boots before its isolate reads a list, and the one a create that recorded the pin boots after. A pin a list no
 * longer names fails as cloud.provider.image_withdrawn (production, 2026-11-20: cloud-native-auto-9d5f6bd6-44156090531-1,
 * trimmed by KEEP_AUTO), so approve and rollback keep every pin listed.
 */
export function platformPins(text: string): string[] {
  const pins = [...text.matchAll(/"CLOUD_VM_API_IMAGE"\s*:\s*"([^"]+)"/gu)].map((m) => m[1]!);
  return [...new Set(pins)];
}

/** The approved entry for a baked candidate: production first, staging last (its order is append-only). */
export type ApproveOptions = WriteOptions & {
  /** The roll's large switch is on (largeImageOn): a list over the binding limit drops its oldest rolls (trimToFit). */
  trimToFit?: boolean;
  /** cmux-platform's pinned image ids (platformPins): never trimmed, by count (trimAuto) or by bytes (trimToFit). */
  keep?: readonly string[];
};

export function approve(text: string, entry: BootImage, options: ApproveOptions = {}): { text: string; previousFirst: string; dropped: Dropped[] } {
  const prod = locate(text, "production").images;
  const staging = locate(text, "staging").images;
  if (prod.some((i) => i.id === entry.id) || staging.some((i) => i.id === entry.id)) throw new Error(`${entry.id} is already approved`);
  const fallback = fallbackImage();
  const dropped: Dropped[] = [];
  const keep = options.keep ?? [];
  const fit = (images: BootImage[], env: Env): BootImage[] => {
    if (options.trimToFit !== true) return images;
    const trimmed = trimToFit(images, BOOT_ENTRY[env] === "first", keep);
    dropped.push(...trimmed.dropped.map((d) => ({ env, id: d.image.id, revision: d.image.revision, why: d.why })));
    return trimmed.images;
  };
  // Both lists are one file, deployed with one Worker source, so the entry is the same in both: its large image too.
  const nextProd = fit(withFallback(trimAuto([{ ...entry, services: [...SERVICES.production] }, ...prod], true, keep), "production", fallback), "production");
  const nextStaging = fit(withFallback(trimAuto([...staging, { ...entry, services: [...SERVICES.staging] }], false, keep), "staging", fallback), "staging");
  for (const [before, after, env] of [[prod, nextProd, "production"], [staging, nextStaging, "staging"]] as const) {
    for (const id of keep) {
      if (before.some((i) => i.id === id) && !after.some((i) => i.id === id)) throw new Error(`approve would take cmux-platform's pinned ${id} out of ${env}'s list`);
    }
  }
  let out = replaceList(text, "production", nextProd, options);
  out = replaceList(out, "staging", nextStaging, options);
  return { text: out, previousFirst: prod[0]?.id ?? "", dropped };
}

/**
 * What the promote job says in its summary after a roll: every roll the byte trim dropped (when the commit that
 * dropped it was made), and a large snapshot the bake made and kept that no list names, with its name and id so it can
 * be removed at the provider. `approved` is approve's printed JSON (absent when approve never wrote one); `result` is
 * image-roll-push.sh's: pushed, dry-run, nothing or "" (it failed).
 */
export function rollNotes(candidate: Candidate, approved: { image?: { id?: string; large?: unknown }; dropped?: Dropped[] } | undefined, result: string): string[] {
  const notes: string[] = [];
  if (result === "pushed" || result === "dry-run")
    for (const d of approved?.dropped ?? []) notes.push(`${d.env} VM_BOOT_IMAGES: dropped ${d.id} (revision ${d.revision}): ${d.why}. A create that names it is now refused as withdrawn.`);
  const large: unknown = candidate.large;
  if (typeof large === "object" && large !== null) {
    const { snapshot, snapshot_id: id } = large as CandidateLarge;
    const published = result === "pushed" && approved?.image?.large !== undefined && approved.image.large !== null;
    if (!published) {
      const why = result !== "pushed" ? `the roll's result was ${result || "a failure"}` : "approve left it out: the switch, the Worker or the large image itself (the push step's log says which)";
      notes.push(`Large image ${String(snapshot ?? "(no name)")} (${String(id ?? "no id")}) was baked and kept, and is not published: ${why}. No list names it and nothing boots it; remove it at the provider.`);
    }
  }
  return notes;
}

/**
 * Takes a failed auto-rolled image out of both lists, first or not. A failed image a newer roll sits above stays
 * second only until that newer roll is rolled back, and would then boot again with no check; removing it wherever
 * it is means it can never come back.
 */
export function rollback(text: string, id: string, keep: readonly string[] = []): { text: string; rolledBack: boolean; reason: string; nowFirst: string } {
  const prod = locate(text, "production").images;
  const first = prod[0]?.id ?? "";
  if (!id.startsWith(AUTO_PREFIX)) return { text, rolledBack: false, reason: `${id} is not an auto-rolled image`, nowFirst: first };
  if (keep.includes(id)) return { text, rolledBack: false, reason: `cmux-platform pins ${id} (CLOUD_VM_API_IMAGE); move its pin first`, nowFirst: first };
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
export function rolledImage(candidate: Candidate, revision: string, cmuxTui: string, run: string, attempt: string, options: { large?: boolean } = {}): BootImage {
  const large = options.large === true ? candidateLarge(candidate).large : undefined;
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
    // cmux-platform compares it across rolls: equal means only cmux-tui changed, so a spare stays claimable.
    ...(typeof candidate.inputs_sha256 === "string" && SHA256.test(candidate.inputs_sha256) ? { inputs_sha256: candidate.inputs_sha256 } : {}),
    // Published with the revision or never (largeWriteProblem): the caller passes `large` only when the roll's
    // switch is on and the Worker deployed with the list reads the field.
    ...(large !== undefined ? { large } : {}),
  };
}

// ---- check: each environment boots a recent roll ----

/**
 * Which entry of its list each environment's new machines boot: cmux-platform's CLOUD_VM_API_IMAGE_FOLLOW for that
 * environment (src/server/cloud/vmapi/ImageFollow.ts there). Production follows its first entry, where approve() puts a
 * roll; staging (development shares its list) follows its last, where approve() appends one. A reader that took
 * staging's first entry would boot the oldest hand-approved image (ci-41315172830-1), not the roll.
 */
export const BOOT_ENTRY: Record<Env, "first" | "last"> = { production: "first", staging: "last" };
/** How many rolls an environment's boot image may trail production's newest roll (one rollback in flight). */
export const MAX_ROLLS_BEHIND = 1;

/** The image an environment's new machines boot, by BOOT_ENTRY; "" when its list is empty. */
export function bootedImage(text: string, env: Env): string {
  const images = locate(text, env).images;
  const entry = BOOT_ENTRY[env] === "first" ? images[0] : images[images.length - 1];
  return entry?.id ?? "";
}

/**
 * Each environment's boot image, and how many rolls it trails production's newest roll (production's auto-rolled
 * entries, newest first). An image that is no roll at all, or a roll production no longer lists, trails every listed
 * roll. Production with no rolled entry has nothing to trail: every environment is 0 behind.
 */
export function bootDrift(text: string, maxBehind = MAX_ROLLS_BEHIND): { env: Env; image: string; behind: number; ok: boolean }[] {
  const rolls = locate(text, "production").images.filter((i) => i.id.startsWith(AUTO_PREFIX)).map((i) => i.id);
  return (Object.keys(BOOT_ENTRY) as Env[]).map((env) => {
    const image = bootedImage(text, env);
    const at = rolls.indexOf(image);
    const behind = rolls.length === 0 ? 0 : at < 0 ? rolls.length : at;
    return { env, image, behind, ok: behind <= maxBehind };
  });
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

export type Plan = {
  roll: boolean;
  reason: string;
  pin: string;
  cmuxTui: string;
  dryRun: boolean;
  fixes: FixCommit[];
  fixesTruncated: boolean;
  /**
   * Whether the bake should also make the large image: the switch is on and the tip's Worker reads `large`
   * (largeDecision). The workflow adds the last condition, that this repository deploys the Worker (publish-mode).
   */
  large: boolean;
  /** Why not, when the switch or the Worker says no; "" otherwise. */
  largeReason: string;
};

/**
 * Whether a roll planned now could publish a large image, as far as this checkout can tell. A large snapshot that
 * approve will not write is a wasted bake and an orphan at the provider, so the bake is asked for one only when the
 * switch is on and the Worker here reads `large`: the same two questions approve asks at the tip it lands on.
 */
export async function largeDecision(modeText: string, workerDir: string): Promise<{ large: boolean; largeReason: string }> {
  if (!largeImageOn(modeText)) return { large: false, largeReason: "images/cmux-vm/auto-roll.json does not say large_image: true" };
  if (!(await workerReadsLarge(workerDir))) return { large: false, largeReason: "the switch is on, and the Worker here does not read `large` (or its dependencies are not installed to ask it): no large image is baked" };
  return { large: true, largeReason: "" };
}

/**
 * The roll's large image switch (auto-roll.json `large_image`, off when absent): on, the roll's bake also makes and
 * smokes the large image, and approve publishes it with the revision when the Worker reads `large`. Turn it on only
 * after the Worker that reads `large` is deployed everywhere the lists are (cmux-platform's copy too, in its mode).
 */
export function largeImageOn(text: string): boolean {
  const value = (JSON.parse(text) as { large_image?: unknown }).large_image;
  if (value === undefined) return false;
  if (typeof value !== "boolean") throw new Error(`auto-roll.json large_image must be true or false, not ${JSON.stringify(value)}`);
  return value;
}

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

/**
 * Why PIN must not roll onto the tip whose lock pins PINNED ("" when it may): PIN is older. plan() refuses an older
 * build only against the pin at plan time, and a newer roll can land while this one bakes. Roll 44191283358's
 * re-run (attempt 2, 2026-11-18) promoted cmux-tui 6c776483 at 04:53Z, 23 min after roll 44224051230 had put
 * ecd5f536 first: image-roll-push.sh wrote the older pin over the tip's newer one and approve() put it first in
 * production. Fails closed like plan(): a shallow checkout or a commit the checkout lacks throws.
 */
function behindTip(pin: string, pinned: string): string {
  if (!/^[0-9a-f]{40}$/u.test(pin)) throw new Error("--pin must be 40 hex");
  if (pin === pinned) return "";
  if (gitOut(["rev-parse", "--is-shallow-repository"]) !== "false") throw new Error("behind needs full history; the checkout is shallow (fetch-depth: 0)");
  for (const commit of [pin, pinned]) {
    if (!gitOk(["cat-file", "-e", `${commit}^{commit}`])) throw new Error(`cmux-tui ${commit.slice(0, 12)} is not in this checkout; fetch it first`);
  }
  if (!gitOk(["merge-base", "--is-ancestor", pin, pinned])) return "";
  return `cmux-tui ${pin.slice(0, 12)} is older than the tip's pinned ${pinned.slice(0, 12)}: a newer roll landed while this one baked`;
}

async function plan(opts: { event: string; commit: string; before: string; dryRun: string; tip: string; lock: string; modeFile: string; worker: string }): Promise<Plan> {
  const modeText = readFileSync(opts.modeFile, "utf8");
  return { ...(await planRoll(opts, modeOf(modeText))), ...(await largeDecision(modeText, opts.worker)) };
}

type RollPlan = Omit<Plan, "large" | "largeReason">;
async function planRoll(opts: { event: string; commit: string; before: string; dryRun: string; tip: string; lock: string }, mode: "off" | "dry-run" | "live"): Promise<RollPlan> {
  const dryRun = opts.dryRun === "true" ? true : opts.dryRun === "false" ? false : mode !== "live";
  const pinned = pinnedCmuxTui(readFileSync(opts.lock, "utf8"));
  const none = (reason: string): RollPlan => ({ roll: false, reason, pin: "", cmuxTui: pinned, dryRun, fixes: [], fixesTruncated: false });
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

/** --platform-wrangler PATH: cmux-platform's root wrangler.jsonc, whose CLOUD_VM_API_IMAGE pins approve and rollback keep. */
function pinsFrom(rest: string[]): string[] {
  const file = rest.includes("--platform-wrangler") ? arg(rest, "--platform-wrangler") : "";
  if (!file) return [];
  const pins = platformPins(readFileSync(file, "utf8"));
  if (pins.length === 0) throw new Error(`${file} names no CLOUD_VM_API_IMAGE: not cmux-platform's wrangler.jsonc`);
  return pins;
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
      modeFile: arg(rest, "--mode-file", MODE_FILE),
      worker: arg(rest, "--worker", path.dirname(DEFAULT_WRANGLER)),
    });
    console.log(JSON.stringify(result, null, 2));
    return 0;
  }
  if (command === "worker-reads-large") {
    // workerReadsLarge's child. Its last line is the answer; a throw or a non-zero exit is a no to the caller.
    console.log(JSON.stringify({ reads: await loadedWorkerReadsLarge(arg(rest, "--worker")) }));
    return 0;
  }
  if (command === "notes") {
    const read = (file: string): unknown => {
      try {
        return JSON.parse(readFileSync(file, "utf8"));
      } catch {
        return undefined;
      }
    };
    const approveFile = arg(rest, "--approve", "");
    const approved = approveFile === "" ? undefined : (read(approveFile) as Parameters<typeof rollNotes>[1]);
    const candidate = JSON.parse(readFileSync(arg(rest, "--candidate"), "utf8")) as Candidate;
    for (const note of rollNotes(candidate, approved, arg(rest, "--result", ""))) console.log(note);
    return 0;
  }
  if (command === "behind") {
    gitCwd = path.resolve(arg(rest, "--repo", ROOT));
    const reason = behindTip(arg(rest, "--pin"), pinnedCmuxTui(readFileSync(lock, "utf8")));
    console.log(JSON.stringify({ behind: reason !== "", reason }, null, 2));
    return reason ? 3 : 0;
  }
  if (command === "approve") {
    const candidate = JSON.parse(readFileSync(arg(rest, "--candidate"), "utf8")) as Candidate;
    const lockText = readFileSync(lock, "utf8");
    const digest = createHash("sha256").update(lockText).digest("hex");
    if (digest !== candidate.lock_sha256) {
      console.error(`approve: the lock here (${digest.slice(0, 12)}) is not the lock the image was baked from (${candidate.lock_sha256.slice(0, 12)}); the tip moved its image inputs`);
      return 4;
    }
    // The large image is published with this revision or never: only with the switch on at this tip and beside a
    // Worker that reads `large`. Anything else rolls the image as it is without one, and says why.
    const wanted = candidate.large !== undefined;
    const switchOn = largeImageOn(readFileSync(MODE_FILE, "utf8"));
    const reads = wanted && switchOn ? await workerReadsLarge(path.dirname(wrangler)) : false;
    const entry = rolledImage(candidate, arg(rest, "--revision"), pinnedCmuxTui(lockText), arg(rest, "--run"), arg(rest, "--attempt"), { large: switchOn && reads });
    if (wanted && entry.large === undefined) {
      const why = !switchOn
        ? "images/cmux-vm/auto-roll.json does not say large_image: true"
        : !reads
          ? `the Worker beside ${path.relative(process.cwd(), wrangler) || wrangler} does not read \`large\` (or its source or dependencies are not there to ask)`
          : (candidateLarge(candidate).skipped ?? "unknown");
      console.error(`approve: ${entry.id} is published without the candidate's large image: ${why}`);
    }
    const before = readFileSync(wrangler, "utf8");
    const { text, previousFirst, dropped } = approve(before, entry, { workerReadsLarge: reads, trimToFit: switchOn, keep: pinsFrom(rest) });
    for (const d of dropped) console.error(`approve: ${d.env} VM_BOOT_IMAGES: dropped ${d.id} (revision ${d.revision}): ${d.why}`);
    writeFileSync(wrangler, text);
    console.log(JSON.stringify({ image: { id: entry.id, revision: entry.revision, snapshotId: entry.snapshotId, large: entry.large ?? null }, previousFirst, dropped }, null, 2));
    return 0;
  }
  if (command === "lists") {
    JSON.parse(readFileSync(lock, "utf8"));
    const text = readFileSync(wrangler, "utf8");
    let reads: boolean | undefined;
    let ok = true;
    for (const env of ["staging", "production"] as const) {
      const images = locate(text, env).images;
      const bytes = Buffer.byteLength(JSON.stringify(images), "utf8");
      console.log(`${env} VM_BOOT_IMAGES: ${bytes} bytes (at most ${MAX_BYTES})`);
      if (bytes > MAX_BYTES) {
        console.error(`lists: ${env} VM_BOOT_IMAGES is ${bytes} bytes, over ${MAX_BYTES}`);
        ok = false;
      }
      const sized = images.filter((i) => i.large !== undefined).map((i) => i.id);
      if (sized.length === 0) continue;
      reads ??= await workerReadsLarge(path.dirname(wrangler));
      if (!reads) {
        console.error(`lists: ${env} VM_BOOT_IMAGES: ${sized.join(", ")} carry a large image, and this commit's Worker does not read \`large\`: it would disable every image`);
        ok = false;
      }
    }
    return ok ? 0 : 1;
  }
  if (command === "rollback") {
    const before = readFileSync(wrangler, "utf8");
    const result = rollback(before, arg(rest, "--image"), pinsFrom(rest));
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
  if (command === "check") {
    const max = Number(arg(rest, "--max-behind", String(MAX_ROLLS_BEHIND)));
    if (!Number.isInteger(max) || max < 0) throw new Error("--max-behind must be a non-negative integer");
    const drift = bootDrift(readFileSync(wrangler, "utf8"), max);
    console.log(JSON.stringify(drift, null, 2));
    for (const d of drift.filter((x) => !x.ok))
      console.error(`check: ${d.env} boots ${d.image || "no image"} (its ${BOOT_ENTRY[d.env]} entry), ${d.behind} rolls behind production's newest; at most ${max}`);
    return drift.every((d) => d.ok) ? 0 : 1;
  }
  console.error("usage: auto-roll.ts plan|approve|lists|notes|rollback|settle|check ... (see the header)");
  return 2;
}

const isEntryPoint = process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntryPoint) process.exit(await main(process.argv.slice(2)));
