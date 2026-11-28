#!/usr/bin/env bun
/**
 * Tags existing Freestyle machines with the cmux account that owns them, as
 * Freestyle's `customer` field (issue #27667). New machines are tagged at
 * create and untagged ones on their next wake; this reaches the rest.
 *
 * Ownership comes from the target's `cloud_vms` rows, read in a read-only
 * transaction: a machine is tagged with its row's `user_id` only when every
 * row naming it agrees. Machines no row names (another environment's, a
 * benchmark's, a leak) are counted and never guessed at. The Freestyle account
 * is shared by every environment, so run it once per target.
 *
 * Dry run by default: prints every machine it would change, from what to what,
 * and changes nothing. `--apply` sends `PATCH /v5/vms/{id}` with only
 * `customer` (or `customerId: null` for a deleted account's machine that a
 * shared team kept), which leaves a paused or stopped machine as it was.
 * Rerunning is safe: a machine already in line plans nothing.
 *
 * Production's FREESTYLE_API_KEY is a Sensitive Vercel variable, which
 * `vercel env pull` returns empty, so export it (it is the one Freestyle
 * account every environment shares); an exported key wins over the pulled one.
 *
 * Usage (from web/):
 *   set -a; source ~/.secrets/cmux.env; set +a
 *   bun scripts/cloud-vm/backfill-freestyle-customers.ts production
 *   bun scripts/cloud-vm/backfill-freestyle-customers.ts production --apply --limit 5   # canary
 *   bun scripts/cloud-vm/backfill-freestyle-customers.ts production --apply
 *     [--concurrency <n>]   parallel updates, default 4
 *     [--show-unowned]      also list machines no row names
 */
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import { Freestyle, FreestyleApiError } from "freestyle";
import type { Pool } from "pg";
import { createPlanetScaleOperatorPool, PlanetScaleOperatorConfigError } from "./planetscale-operator.mjs";
import { loadTargetEnv, parseWebDirAndTarget } from "./projects.mjs";
import {
  planFreestyleCustomerBackfill,
  summarizeBackfill,
  type BackfillAction,
  type BackfillOwnerRow,
  type BackfillVm,
} from "./freestyleCustomerBackfill";

const usage = "Usage: backfill-freestyle-customers.ts [web-dir] <staging|production> [--apply] [--limit <n>] [--concurrency <n>] [--show-unowned]";
const LIST_PAGE = 100;

class BackfillError extends Error {}

function parseOptions(rest: readonly string[]) {
  const options = { apply: false, showUnowned: false, limit: Number.POSITIVE_INFINITY, concurrency: 4 };
  for (let index = 0; index < rest.length; index++) {
    const arg = rest[index];
    if (arg === "--apply") options.apply = true;
    else if (arg === "--show-unowned") options.showUnowned = true;
    else if (arg === "--limit" || arg === "--concurrency") {
      const value = Number(rest[++index]);
      if (!Number.isInteger(value) || value < 1) throw new Error(`${arg} needs a positive integer\n${usage}`);
      options[arg === "--limit" ? "limit" : "concurrency"] = value;
    } else throw new Error(`Unknown argument: ${arg}\n${usage}`);
  }
  return options;
}

/** Every row that names a Freestyle machine, read without the ability to write. */
async function readOwnerRows(pool: Pool): Promise<BackfillOwnerRow[]> {
  const client = await pool.connect();
  try {
    await client.query("begin transaction read only");
    const result = await client.query<{ id: string; provider_vm_id: string; user_id: string; status: string }>(
      "select id, provider_vm_id, user_id, status::text as status from cloud_vms where provider = 'freestyle' and provider_vm_id is not null",
    );
    await client.query("commit");
    return result.rows.map((row) => ({ cloudVmId: row.id, providerVmId: row.provider_vm_id, userId: row.user_id, status: row.status }));
  } catch (error) {
    await client.query("rollback").catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

async function listFreestyleVms(fs: Freestyle): Promise<{ vms: BackfillVm[]; totalCount: number }> {
  const byId = new Map<string, BackfillVm>();
  let totalCount = 0;
  for (let offset = 0; ; offset += LIST_PAGE) {
    const page = await fs.vms.list({ limit: LIST_PAGE, offset });
    totalCount = page.totalCount;
    const known = byId.size;
    for (const vm of page.vms) byId.set(vm.id, vm);
    // A page with nothing new means the listing stopped advancing; stop with it.
    if (page.vms.length < LIST_PAGE || byId.size === known) break;
  }
  return { vms: [...byId.values()], totalCount };
}

function describe(action: BackfillAction): string {
  switch (action.kind) {
    case "tag":
      return `tag ${action.vmId} ${action.state} customer ${action.from ?? "none"} -> ${action.to} rows=${action.cloudVmIds.join(",")} status=${action.rowStatuses.join(",")}`;
    case "detach":
      return `detach ${action.vmId} ${action.state} customer ${action.from} -> none (owner is a deleted account) rows=${action.cloudVmIds.join(",")}`;
    case "conflict":
      return `conflict ${action.vmId} rows name users ${action.userIds.join(",")}: not tagged`;
    case "invalid":
      return `invalid ${action.vmId} owner ${action.userId} is not a Freestyle customer id: not tagged`;
    case "unowned":
      return `unowned ${action.vmId} ${action.state} cmux=${action.cmux ?? "-"}`;
    case "tagged":
      return `tagged ${action.vmId}`;
  }
}

type ChangeAction = Extract<BackfillAction, { kind: "tag" | "detach" }>;

async function applyTag(fs: Freestyle, action: ChangeAction): Promise<"tagged" | "gone" | "failed"> {
  try {
    const to = action.kind === "tag" ? action.to : null;
    await fs.vms.ref(action.vmId).update(to ? { customer: { customerId: to } } : { customerId: null });
    console.log(`applied ${action.vmId} -> ${to ?? "none"}`);
    return "tagged";
  } catch (error) {
    if (error instanceof FreestyleApiError && error.status === 404) {
      console.log(`gone ${action.vmId}: deleted since the listing`);
      return "gone";
    }
    const reason = error instanceof FreestyleApiError ? `${error.status} ${error.code ?? ""}`.trim() : "request failed";
    console.log(`failed ${action.vmId}: ${reason}`);
    return "failed";
  }
}

const { webDir, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
const options = parseOptions(rest);

const program = Effect.acquireUseRelease(
  Effect.try({
    try: () => {
      const env = loadTargetEnv(project);
      const apiKey = process.env.FREESTYLE_API_KEY?.trim() || env.FREESTYLE_API_KEY?.trim();
      if (!apiKey) throw new BackfillError(`${project.label}: FREESTYLE_API_KEY is missing; export it (Vercel does not pull Sensitive values)`);
      return { env, apiKey, pool: createPlanetScaleOperatorPool(webDir, env, project.label) as Pool };
    },
    // The operator config error names the problem without the URL itself.
    catch: (error) => error instanceof BackfillError || error instanceof PlanetScaleOperatorConfigError
      ? new BackfillError(error.message)
      : new BackfillError(`${project.label}: could not load the target environment`),
  }),
  ({ env, apiKey, pool }) => Effect.gen(function* () {
    const fs = new Freestyle({ apiKey, ...(env.FREESTYLE_API_URL ? { baseUrl: env.FREESTYLE_API_URL } : {}) });
    const rows = yield* Effect.tryPromise(() => readOwnerRows(pool));
    const { vms, totalCount } = yield* Effect.tryPromise(() => listFreestyleVms(fs));
    const actions = planFreestyleCustomerBackfill(vms, rows);
    for (const action of actions) {
      if (action.kind === "tag" || action.kind === "detach" || action.kind === "conflict" || action.kind === "invalid") console.log(describe(action));
      else if (action.kind === "unowned" && options.showUnowned) console.log(describe(action));
    }
    const tags = actions.filter((action): action is ChangeAction => action.kind === "tag" || action.kind === "detach");
    const selected = tags.slice(0, options.limit);
    const outcomes = { tagged: 0, gone: 0, failed: 0, rechecked: 0 };
    if (options.apply) {
      const results = yield* Effect.forEach(selected, (action) => Effect.promise(() => applyTag(fs, action)), { concurrency: options.concurrency });
      for (const result of results) outcomes[result] += 1;
      // An account deleted while this ran may have cleared a machine this run
      // then tagged. Read the owners again after every write: a deletion that
      // committed before this read is caught here, and one after it clears
      // its machines itself, after these writes.
      const recheck = yield* Effect.tryPromise(() => readOwnerRows(pool));
      const written = selected.filter((_, index) => results[index] === "tagged");
      const afterWrite = written.map((action): BackfillVm => ({ id: action.vmId, state: action.state, customerId: action.kind === "tag" ? action.to : undefined }));
      const corrections = planFreestyleCustomerBackfill(afterWrite, recheck)
        .filter((action): action is ChangeAction => action.kind === "tag" || action.kind === "detach");
      for (const action of corrections) console.log(`recheck ${describe(action)}`);
      const corrected = yield* Effect.forEach(corrections, (action) => Effect.promise(() => applyTag(fs, action)), { concurrency: options.concurrency });
      outcomes.failed += corrected.filter((result) => result === "failed").length;
      outcomes.rechecked = corrections.length;
    }
    // Offset paging drifts when machines come and go mid-listing; a short
    // listing may have skipped some, which only a rerun would reach.
    const incomplete = vms.length < totalCount;
    if (incomplete) console.error(`warning: listed ${vms.length} of ${totalCount} Freestyle machines; rerun to reach the rest`);
    const unowned = actions.filter((action): action is Extract<BackfillAction, { kind: "unowned" }> => action.kind === "unowned");
    console.log(JSON.stringify({
      target: project.label,
      mode: options.apply ? "apply" : "dry-run",
      freestyleVms: { listed: vms.length, totalCount },
      ownerRows: rows.length,
      plan: summarizeBackfill(actions),
      retags: tags.filter((action) => action.kind === "tag" && action.from !== null).length,
      unownedCloudVms: unowned.filter((action) => action.cmux === "cloud").length,
      ...(options.apply ? { applied: outcomes, notAttempted: tags.length - selected.length } : {}),
    }, null, 2));
    if (outcomes.failed > 0 || (options.apply && incomplete)) process.exitCode = 1;
  }),
  ({ pool }) => Effect.promise(() => pool.end()),
);

const result = await Effect.runPromiseExit(program);
if (result._tag === "Failure") {
  // Do not render nested SDK/SQL errors: they can contain credentials or rows.
  const error = Cause.failureOption(result.cause);
  console.error(Option.isSome(error) && error.value instanceof BackfillError
    ? error.value.message
    : "Freestyle customer backfill did not complete. Check Vercel, PlanetScale, and Freestyle access; a partial apply is safe to rerun.");
  process.exitCode = 1;
}
