/**
 * The production copy of a dev image: what cloud-vm-image-bake.yml (mode prod-copy) bakes and
 * cloud-vm-image-promote.yml (channel production) promotes. Freestyle snapshots belong to one
 * account, so production boots its own copy, baked on the production account from the same lock
 * with the same flags and recorded as names.production on the dev image's history entry
 * (promote-record.ts --production-copy; scripts/cmux-next/release/promote-lib.ts reads it).
 *
 * Usage (from web/):
 *   bun scripts/cmux-vm-image/prod-copy.ts plan --dev-snapshot <sh-id>
 *     Prints `FLAGS --prod-copy [--agent-tools] [--team-vm]` and `VAR <var>` for bake.ts. Refuses an
 *     entry that is not a PASSED CI bake, one whose lock differs from this checkout's lock, a dev tree
 *     bake, an unknown flag, and an entry that already records names.production. No provider access.
 *   bun scripts/cmux-vm-image/prod-copy.ts account-check
 *     Checks the key (FREESTYLE_API_KEY or FREESTYLE_API_KEY_FILE) is the production account's. Refuses the
 *     dev account's key when it resolves the dev channel's snapshot name to its recorded id. The key
 *     must also resolve a trusted production snapshot recorded in channels/production.json or
 *     names.production in dev.json history. With no such record, it refuses: a missing dev slug
 *     does not prove production identity. Read-only GETs; no automatic account bootstrap.
 */
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SNAPSHOT_ID } from "./cleanup";
import { argValue, freestyleApiKey } from "./guest";
import { lockDigest, PROD_IMAGE_PREFIX } from "./lock";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const DEV = "images/cmux-vm/channels/dev.json";
const LOCK = "images/cmux-vm/inputs.lock.json";
const PRODUCTION = "images/cmux-vm/channels/production.json";
/** bake.ts flags a production copy may repeat; --dev-tree and anything else is refused. */
const COPYABLE = ["--agent-tools", "--team-vm"] as const;

type Json = Record<string, unknown>;
export type CopyPlan = { flags: string[]; var: "CLOUD_FREESTYLE_SNAPSHOT" | "TEAM_VM_SNAPSHOT"; lockSha256: string };

const readDev = (root: string): Json => JSON.parse(readFileSync(path.join(root, DEV), "utf8")) as Json;

/** The bake.ts flags a CI candidate recorded: `images/cmux-vm/bake.ts --a --b (CI run N)`. */
export function recordedFlags(bake: unknown): string[] | undefined {
  if (typeof bake !== "string") return undefined;
  const m = bake.match(/^images\/cmux-vm\/bake\.ts((?: --[a-z-]+)*) \(CI run [0-9]+\)$/);
  return m ? m[1]!.split(" ").filter(Boolean) : undefined;
}

/** Throws unless the dev history entry can be copied to production; returns the copy's bake flags. */
export function planCopy(root: string, devSnapshot: string): CopyPlan {
  if (!SNAPSHOT_ID.test(devSnapshot)) throw new Error(`--dev-snapshot ${JSON.stringify(devSnapshot)} is not a snapshot id`);
  const history = readDev(root).history;
  if (!Array.isArray(history)) throw new Error(`${DEV} has no history array`);
  const entry = (history as Json[]).find((h) => h.snapshot_id === devSnapshot);
  if (!entry) throw new Error(`${devSnapshot} is not in ${DEV} history; only a recorded dev image gets a production copy`);
  const flags = recordedFlags(entry.bake);
  const lock = lockDigest(readFileSync(path.join(root, LOCK), "utf8"));
  const v = entry.var;
  const names = entry.names as Json | undefined;
  const problems = [
    (entry.smoke as Json | undefined)?.result !== "PASSED" && `its smoke is ${JSON.stringify((entry.smoke as Json | undefined)?.result)}, not "PASSED"`,
    typeof entry.run !== "number" && "it is not a CI bake (no run recorded)",
    !flags && `its bake ${JSON.stringify(entry.bake)} is not a CI bake record`,
    flags?.includes("--dev-tree") && "it is a dev tree bake (dev snapshots only)",
    flags?.some((f) => !(COPYABLE as readonly string[]).includes(f)) && `its bake flags ${flags.join(" ")} are not all copyable (${COPYABLE.join(", ")})`,
    v !== "CLOUD_FREESTYLE_SNAPSHOT" && v !== "TEAM_VM_SNAPSHOT" && `its var ${JSON.stringify(v)} is not CLOUD_FREESTYLE_SNAPSHOT or TEAM_VM_SNAPSHOT`,
    flags && (v === "TEAM_VM_SNAPSHOT") !== flags.includes("--team-vm") && `its var ${String(v)} and its bake flags disagree about --team-vm`,
    entry.lock_sha256 !== lock && `its lock_sha256 ${JSON.stringify(entry.lock_sha256)} is not this checkout's ${LOCK} (${lock}): the copy would bake other inputs`,
    names?.production !== undefined && "it already records names.production",
  ].filter((p): p is string => typeof p === "string");
  if (problems.length) throw new Error(`refusing a production copy of ${devSnapshot}: ${problems.join("; ")}`);
  return { flags: ["--prod-copy", ...flags!], var: v as CopyPlan["var"], lockSha256: lock };
}

export type Pointer = { snapshot: string; snapshot_id: string };
const isPointer = (p: unknown, prefix: string): p is Pointer => {
  const r = p as Json | undefined;
  return typeof r?.snapshot === "string" && r.snapshot.startsWith(prefix) && /^[a-z0-9-]+$/.test(r.snapshot) && typeof r.snapshot_id === "string" && SNAPSHOT_ID.test(r.snapshot_id);
};

/** Production snapshots the repo records (channels/production.json pointers and previous, names.production in dev.json history). */
export function productionAnchors(root: string): Pointer[] {
  const file = path.join(root, PRODUCTION);
  const prod = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as Json) : undefined;
  const pointer = (value: unknown, label: string, options: { allowDev?: boolean; allowNull?: boolean; allowEmpty?: (value: unknown) => boolean } = {}): Pointer | undefined => {
    if (value === undefined || (options.allowNull && value === null)) return undefined;
    if (isPointer(value, PROD_IMAGE_PREFIX)) return value;
    // A channel rollback keeps the prior dev pointer in `previous`; it is a valid record, but never
    // an anchor for the production account.
    if (options.allowDev && isPointer(value, "cmuxnp-dev-vmimg-")) return undefined;
    if (options.allowEmpty?.(value)) return undefined;
    throw new Error(`${label} is malformed; refusing to check a production account`);
  };
  const field = (value: Json | undefined, key: string, label: string): unknown => value !== undefined && Object.prototype.hasOwnProperty.call(value, key) ? value[key] : undefined;
  const current = pointer(prod, `${PRODUCTION} current`, { allowEmpty: (value) => {
    const envelope = value as Json | undefined;
    return Boolean(envelope && envelope.env === "production" && !Object.hasOwn(envelope, "snapshot") && !Object.hasOwn(envelope, "snapshot_id"));
  } });
  const previous = pointer(field(prod, "previous", `${PRODUCTION} previous`), `${PRODUCTION} previous`, { allowDev: true, allowNull: true });
  const team = field(prod, "team_vm", `${PRODUCTION} team_vm`) as Json | undefined;
  const teamCurrent = pointer(team, `${PRODUCTION} team_vm`);
  const teamPrevious = pointer(field(team, "previous", `${PRODUCTION} team_vm previous`), `${PRODUCTION} team_vm previous`, { allowDev: true, allowNull: true });
  const history = readDev(root).history;
  const historyProduction = Array.isArray(history) ? (history as Json[]).flatMap((h, i) => {
    const names = h.names as Json | undefined;
    return names !== undefined && Object.prototype.hasOwnProperty.call(names, "production")
      ? [pointer(names.production, `${DEV} history[${i}].names.production`)]
      : [];
  }) : [];
  const candidates = [current, previous, teamCurrent, teamPrevious, ...historyProduction];
  const byId = new Map<string, Pointer>();
  for (const p of candidates) if (isPointer(p, PROD_IMAGE_PREFIX) && !byId.has(p.snapshot_id)) byId.set(p.snapshot_id, p);
  return [...byId.values()];
}

/**
 * Throws unless `resolve` (one account's view of snapshot names) resolves a trusted production
 * snapshot to its recorded id, and does not resolve the dev snapshot to its recorded id.
 * An absent production anchor fails closed, even when the dev snapshot no longer resolves.
 */
export async function accountCheck(root: string, resolve: (name: string) => Promise<string | undefined>): Promise<string> {
  const dev = readDev(root);
  if (!isPointer(dev, "cmuxnp-dev-vmimg-")) throw new Error(`${DEV} has no dev snapshot name and id to check the key against; refusing`);
  if ((await resolve(dev.snapshot)) === dev.snapshot_id) {
    throw new Error(`the Freestyle key resolves the dev channel's ${dev.snapshot} to ${dev.snapshot_id}: it is the dev account's key, not production's; refusing`);
  }
  const anchors = productionAnchors(root);
  if (!anchors.length) {
    throw new Error("no trusted production snapshot is recorded; refusing an unidentified account; bootstrap requires an independently verified production snapshot in channel data");
  }
  for (const a of anchors) if ((await resolve(a.snapshot)) === a.snapshot_id) return `account check passed: not the dev account, and ${a.snapshot} resolves to the recorded ${a.snapshot_id}`;
  throw new Error(`the Freestyle key resolves none of the ${anchors.length} known production snapshots (${anchors.map((a) => a.snapshot).join(", ")}) to its id: it is not the production account's key; refusing`);
}

/** `GET /v5/snapshots/{slug}`: the id, or undefined on 404. The key is read here and never printed. */
export async function freestyleResolve(name: string, env: Record<string, string | undefined> = process.env): Promise<string | undefined> {
  const key = freestyleApiKey(env);
  const base = env.FREESTYLE_API_URL?.trim() || "https://api.freestyle.sh";
  const response = await fetch(`${base}/v5/snapshots/${encodeURIComponent(name)}`, { headers: { authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(20_000) });
  if (response.status === 404) return undefined;
  if (!response.ok) throw new Error(`Freestyle GET /v5/snapshots/${name}: HTTP ${response.status}`);
  return ((await response.json()) as { id?: string }).id;
}

// Bun-only `import.meta.main` is not in TypeScript's ImportMeta type (promote-record.ts).
if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const command = process.argv[2];
  try {
    if (command === "plan") {
      const plan = planCopy(REPO_ROOT, argValue("--dev-snapshot") ?? "");
      console.log(`FLAGS ${plan.flags.join(" ")}`);
      console.log(`VAR ${plan.var}`);
    } else if (command === "account-check") {
      console.log(await accountCheck(REPO_ROOT, (name) => freestyleResolve(name)));
    } else {
      console.error("usage: prod-copy.ts plan --dev-snapshot <sh-id> | account-check");
      process.exit(2);
    }
  } catch (error) {
    console.error(`prod-copy: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}
