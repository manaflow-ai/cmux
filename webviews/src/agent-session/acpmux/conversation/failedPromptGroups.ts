// Prompts that failed one after another for the same cause share one failure line (Leo,
// 2026-10-21: Retry, Edit, Remove and Details repeated under every failed message). Each keeps its
// bubble; the line sits under the last of the run, and its actions act on the whole run
// (PromptDelivery.tsx `DeliveryFailure`). The cause is the structured one (promptFailureCause.ts and
// the refusal's reason or code), never the message's words; another cause, or any row drawn
// between, starts a run of its own.
import { createContext, useMemo } from "react";
import type { AcpmuxRow } from "../model";
import { promptFailureCause } from "../promptFailureCause";

/// A run of two or more failed prompts, their row ids in the order they were sent.
export type FailedPromptGroup = { rowIds: readonly string[] };
/// Each row of such a run, to its run. A failed prompt that is not in it draws its own line.
export type FailedPromptGroups = ReadonlyMap<string, FailedPromptGroup>;

const NONE: FailedPromptGroups = new Map();
export const FailedPromptGroupsContext = createContext<FailedPromptGroups>(NONE);

/// What two failed prompts must share to share a line; undefined for any other row.
function failureKey(row: AcpmuxRow): string | undefined {
  if (row.kind !== "user" || !row.failed) return undefined;
  const delivery = row.delivery;
  return `${promptFailureCause(delivery)}|${delivery?.reason ?? delivery?.code ?? ""}`;
}

/// The runs in `rows` (the transcript's drawn rows, oldest first), each as its row ids.
export function failedPromptRuns(rows: readonly AcpmuxRow[]): string[][] {
  const runs: string[][] = [];
  let run: string[] = [];
  let key: string | undefined;
  for (const row of rows) {
    const next = failureKey(row);
    if (next === undefined || next !== key) {
      if (run.length > 1) runs.push(run);
      run = [];
    }
    key = next;
    if (next !== undefined) run.push(row.id);
  }
  if (run.length > 1) runs.push(run);
  return runs;
}

/// The runs of `rows` as a map that keeps its identity while the runs stay the same, so a new
/// snapshot redraws no failure line.
export function useFailedPromptGroups(rows: readonly AcpmuxRow[]): FailedPromptGroups {
  const signature = useMemo(
    () =>
      failedPromptRuns(rows)
        .map((run) => run.join("\n"))
        .join("\n\n"),
    [rows],
  );
  return useMemo(() => {
    if (!signature) return NONE;
    const groups = new Map<string, FailedPromptGroup>();
    for (const run of signature.split("\n\n")) {
      const group = { rowIds: run.split("\n") };
      for (const id of group.rowIds) groups.set(id, group);
    }
    return groups;
  }, [signature]);
}
