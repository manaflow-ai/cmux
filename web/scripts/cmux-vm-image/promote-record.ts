/**
 * Appends a bake run's dev channel candidate (cloud-vm-image-bake.yml keep_snapshot writes
 * channel-dev.json) to images/cmux-vm/channels/dev.json `history`, the record promote.ts
 * requires before it promotes a snapshot. The entry is the candidate minus `schema` and `env`.
 * Used by cloud-vm-image-promote.yml; no provider access.
 *
 * Usage (from web/): bun scripts/cmux-vm-image/promote-record.ts --candidate <channel-dev.json> --snapshot <sh-id> --run <bake run id>
 * Prints `VAR <CLOUD_FREESTYLE_SNAPSHOT|TEAM_VM_SNAPSHOT>`, the --var promote.ts takes.
 */
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SNAPSHOT_ID } from "./cleanup";
import { argValue } from "./guest";

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

const same = (a: Json, b: Json) => {
  const { promotion_smokes: _, ...rest } = a;
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

// Bun-only `import.meta.main` is not in TypeScript's ImportMeta type (check-devbox-image-reachable.ts).
if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const candidate = argValue("--candidate");
  const snapshot = argValue("--snapshot");
  const run = argValue("--run");
  if (!candidate || !snapshot || !run) {
    console.error("usage: promote-record.ts --candidate <channel-dev.json> --snapshot <sh-id> --run <bake run id>");
    process.exit(2);
  }
  try {
    const result = recordCandidate(REPO_ROOT, JSON.parse(readFileSync(candidate, "utf8")) as Json, snapshot, run);
    console.log(result.appended ? `appended ${snapshot} to ${DEV} history` : `${DEV} history already records ${snapshot}`);
    console.log(`VAR ${result.var}`);
  } catch (error) {
    console.error(`promote-record: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}
