import type { AcpmuxActivity, AcpmuxRow } from "../../agent-session/acpmux/model";
import type { HomeRun, HomeRunStep } from "./types";
import { stepActivity } from "./runMessages";

/** Consecutive tool steps as one agent-pane activity row; text and thought steps between them. */
export type RunBlock =
  | { kind: "tools"; key: string; row: AcpmuxRow }
  | { kind: "talk"; key: string; step: HomeRunStep }
  | { kind: "thought"; key: string; step: HomeRunStep }
  | { kind: "note"; key: string; step: HomeRunStep };

export function runBlocks(run: HomeRun, steps: readonly HomeRunStep[]): RunBlock[] {
  const blocks: RunBlock[] = [];
  let items: AcpmuxActivity[] = [];
  let first: HomeRunStep | undefined;
  const flush = () => {
    if (!first || items.length === 0) return;
    blocks.push({
      kind: "tools",
      key: `tools-${first.id}`,
      row: {
        id: `${run.id}:${first.id}`,
        version: run.rev,
        at: first.at,
        kind: "activity",
        items,
        // Every call on its own row: a run is read step by step, never folded into one line.
        settled: false,
      },
    });
    items = [];
    first = undefined;
  };
  for (const step of steps) {
    if (step.kind === "tool") {
      first ??= step;
      items.push(stepActivity(step));
    } else {
      flush();
      blocks.push({ kind: step.kind, key: step.id, step });
    }
  }
  flush();
  return blocks;
}
