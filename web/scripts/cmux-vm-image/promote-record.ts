/**
 * Appends a bake run's dev channel candidate (cloud-vm-image-bake.yml keep_snapshot writes
 * channel-dev.json) to images/cmux-vm/channels/dev.json `history`, the record promote.ts
 * requires before it promotes a snapshot. The entry is the candidate minus `schema` and `env`.
 * Used by cloud-vm-image-promote.yml; no provider access.
 *
 * --production-copy (promote channel production) instead records a prod-copy bake's
 * channel-production.json as names.production of the dev image's existing history entry,
 * the production copy promote.ts boots (prod-copy.ts).
 *
 * Usage (from web/): bun scripts/cmux-vm-image/promote-record.ts [--production-copy] --candidate <channel-dev.json|channel-production.json> --snapshot <sh-id> --run <bake run id>
 * Prints `VAR <CLOUD_FREESTYLE_SNAPSHOT|TEAM_VM_SNAPSHOT>`, the --var promote.ts takes.
 */
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SNAPSHOT_ID } from "./cleanup";
import { argValue, hasFlag } from "./guest";
import { PROD_IMAGE_PREFIX } from "./lock";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const DEV = "images/cmux-vm/channels/dev.json";
const VARS = ["CLOUD_FREESTYLE_SNAPSHOT", "TEAM_VM_SNAPSHOT"] as const;

type Json = Record<string, unknown>;

/** Throws on a candidate that is not this run's PASSED dev snapshot; returns the history entry. */
export function historyEntry(candidate: Json, snapshot: string, run: string): Json {
  if (!SNAPSHOT_ID.test(snapshot)) throw new Error(`--snapshot ${JSON.stringify(snapshot)} is not a snapshot id`);
  if (!/^[0-9]+$/.test(run)) throw new Error(`--run ${JSON.stringify(run)} is not a run id`);
  const { schema, env, ...entry } = candidate;
  const smoke = entry.smoke as Json | undefined;
  const problems = [
    schema !== 1 && `schema is ${JSON.stringify(schema)}, not 1`,
    env !== "dev" && `env is ${JSON.stringify(env)}, not "dev"`,
    entry.snapshot_id !== snapshot && `snapshot_id is ${JSON.stringify(entry.snapshot_id)}, not ${snapshot}`,
    entry.run !== Number(run) && `run is ${JSON.stringify(entry.run)}, not ${run}`,
    smoke?.result !== "PASSED" && `smoke.result is ${JSON.stringify(smoke?.result)}, not "PASSED"`,
    !(typeof entry.snapshot === "string" && /^cmuxnp-dev-vmimg-[a-z0-9-]+$/.test(entry.snapshot)) && `snapshot ${JSON.stringify(entry.snapshot)} is not a cmuxnp-dev-vmimg- name`,
    !VARS.includes(entry.var as (typeof VARS)[number]) && `var ${JSON.stringify(entry.var)} is not ${VARS.join(" or ")}`,
  ].filter((p): p is string => typeof p === "string");
  if (problems.length) throw new Error(`refusing the candidate: ${problems.join("; ")}`);
  return entry;
}

/** The bake fields only: promotion_smokes and names (the per-channel copies) are added to an entry after it is recorded. */
const same = (a: Json, b: Json) => {
  const { promotion_smokes: _, names: _names, ...rest } = a;
  return JSON.stringify(Object.entries(rest).sort()) === JSON.stringify(Object.entries(b).sort());
};

/** Appends the entry to dev.json history (newest last); a byte-identical entry already there is kept, a different one refuses. */
export function recordCandidate(root: string, candidate: Json, snapshot: string, run: string): { var: string; appended: boolean } {
  const entry = historyEntry(candidate, snapshot, run);
  const file = path.join(root, DEV);
  const dev = JSON.parse(readFileSync(file, "utf8")) as Json;
  if (!Array.isArray(dev.history)) throw new Error(`${DEV} has no history array; refusing to write one`);
  const history = dev.history as Json[];
  const existing = history.find((h) => h.snapshot_id === snapshot);
  if (existing) {
    if (!same(existing, entry)) throw new Error(`${DEV} history already has ${snapshot} with different fields; entries are never edited`);
    return { var: entry.var as string, appended: false };
  }
  dev.history = [...history, entry];
  writeFileSync(file, `${JSON.stringify(dev, null, 2)}\n`);
  return { var: entry.var as string, appended: true };
}

/**
 * Records a prod-copy bake (channel-production.json) as names.production of the dev entry `devSnapshot`.
 * Throws on a candidate that is not this run's PASSED production copy of that entry (same var and lock).
 * The same copy recorded already is kept; a different one refuses.
 */
export function recordProductionCopy(root: string, candidate: Json, devSnapshot: string, run: string): { var: string; appended: boolean } {
  if (!SNAPSHOT_ID.test(devSnapshot)) throw new Error(`--snapshot ${JSON.stringify(devSnapshot)} is not a snapshot id`);
  if (!/^[0-9]+$/.test(run)) throw new Error(`--run ${JSON.stringify(run)} is not a run id`);
  const file = path.join(root, DEV);
  const dev = JSON.parse(readFileSync(file, "utf8")) as Json;
  if (!Array.isArray(dev.history)) throw new Error(`${DEV} has no history array; refusing to write one`);
  const history = dev.history as Json[];
  const index = history.findIndex((h) => h.snapshot_id === devSnapshot);
  const entry = history[index];
  const { schema, env, copy_of, ...copy } = candidate;
  const smoke = copy.smoke as Json | undefined;
  const problems = [
    !entry && `${devSnapshot} is not in ${DEV} history`,
    entry && (entry.smoke as Json | undefined)?.result !== "PASSED" && `the dev entry's smoke is not PASSED`,
    schema !== 1 && `schema is ${JSON.stringify(schema)}, not 1`,
    env !== "production" && `env is ${JSON.stringify(env)}, not "production"`,
    copy_of !== devSnapshot && `copy_of is ${JSON.stringify(copy_of)}, not ${devSnapshot}`,
    copy.run !== Number(run) && `run is ${JSON.stringify(copy.run)}, not ${run}`,
    smoke?.result !== "PASSED" && `smoke.result is ${JSON.stringify(smoke?.result)}, not "PASSED"`,
    !(typeof copy.snapshot === "string" && copy.snapshot.startsWith(PROD_IMAGE_PREFIX) && /^[a-z0-9-]+$/.test(copy.snapshot)) && `snapshot ${JSON.stringify(copy.snapshot)} is not a ${PROD_IMAGE_PREFIX} name`,
    !(typeof copy.snapshot_id === "string" && SNAPSHOT_ID.test(copy.snapshot_id)) && `snapshot_id ${JSON.stringify(copy.snapshot_id)} is not a snapshot id`,
    copy.snapshot_id === devSnapshot && "snapshot_id is the dev image's own id",
    entry && copy.var !== (entry.var ?? "CLOUD_FREESTYLE_SNAPSHOT") && `var ${JSON.stringify(copy.var)} is not the dev entry's ${JSON.stringify(entry.var ?? "CLOUD_FREESTYLE_SNAPSHOT")}`,
    entry && (typeof copy.lock_sha256 !== "string" || copy.lock_sha256 !== entry.lock_sha256) && `lock_sha256 ${JSON.stringify(copy.lock_sha256)} is not the dev entry's ${JSON.stringify(entry.lock_sha256)}`,
  ].filter((p): p is string => typeof p === "string");
  if (problems.length) throw new Error(`refusing the production copy: ${problems.join("; ")}`);
  const names = (entry!.names as Json | undefined) ?? {};
  if (names.production !== undefined) {
    if (JSON.stringify(Object.entries(names.production as Json).sort()) !== JSON.stringify(Object.entries(copy).sort())) {
      throw new Error(`${DEV} history ${devSnapshot} already records a different names.production; a copy is never replaced`);
    }
    return { var: copy.var as string, appended: false };
  }
  history[index] = { ...entry!, names: { ...names, production: copy } };
  writeFileSync(file, `${JSON.stringify(dev, null, 2)}\n`);
  return { var: copy.var as string, appended: true };
}

// Bun-only `import.meta.main` is not in TypeScript's ImportMeta type (check-devbox-image-reachable.ts).
if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const candidate = argValue("--candidate");
  const snapshot = argValue("--snapshot");
  const run = argValue("--run");
  if (!candidate || !snapshot || !run) {
    console.error("usage: promote-record.ts [--production-copy] --candidate <channel-dev.json|channel-production.json> --snapshot <sh-id> --run <bake run id>");
    process.exit(2);
  }
  try {
    const parsed = JSON.parse(readFileSync(candidate, "utf8")) as Json;
    const production = hasFlag("--production-copy");
    const result = production ? recordProductionCopy(REPO_ROOT, parsed, snapshot, run) : recordCandidate(REPO_ROOT, parsed, snapshot, run);
    if (production) console.log(result.appended ? `recorded names.production of ${snapshot} in ${DEV} history` : `${DEV} history already records this production copy of ${snapshot}`);
    else console.log(result.appended ? `appended ${snapshot} to ${DEV} history` : `${DEV} history already records ${snapshot}`);
    console.log(`VAR ${result.var}`);
  } catch (error) {
    console.error(`promote-record: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}
