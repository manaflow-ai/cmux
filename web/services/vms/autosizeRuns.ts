/**
 * Auto-sizing's measured runs (autosize.ts): a VM created by a pick is tagged
 * with its repo and task kind, its guest's samples keep its peaks
 * (resourceUsage.ts), and the next pick of that repo and task kind reads the
 * newest of them. Both sides are best effort: a pick never waits on or fails
 * for them, it falls back to the table.
 */
import * as Effect from "effect/Effect";
import { MAX_MEASURED_RUNS, measuredRunFromMetadata, type AutosizeTag, type MeasuredRun } from "./autosize";
import { VmRepository } from "./repository";
import { VM_RESOURCE_PEAK_KEY } from "./resourceUsage";

/** The longest a create waits for its measured runs before it picks from the table. */
export const AUTOSIZE_RUNS_READ_MS = 1_500;

/** The owner's newest measured runs of a repo and task kind, newest first; none when the store cannot say. */
export function listMeasuredRuns(input: { readonly userId: string; readonly repoKey: string; readonly taskKind: string }) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    if (!repo.listAutosizeRuns) return [] as MeasuredRun[];
    const rows = yield* repo.listAutosizeRuns({ ...input, limit: MAX_MEASURED_RUNS });
    return rows.flatMap((metadata) => measuredRunFromMetadata(metadata, VM_RESOURCE_PEAK_KEY) ?? []);
  }).pipe(
    Effect.timeout(AUTOSIZE_RUNS_READ_MS),
    Effect.catchAll(() => Effect.succeed([] as MeasuredRun[])),
  );
}

/** Tags the owner's new VM as a run of the pick, so its peaks count for the next one. */
export function tagMeasuredRun(input: { readonly userId: string; readonly provider: string; readonly providerVmId: string; readonly tag: AutosizeTag }) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    if (!repo.tagAutosizeRun) return false;
    return yield* repo.tagAutosizeRun(input);
  }).pipe(Effect.catchAll(() => Effect.succeed(false)));
}
