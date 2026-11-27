import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { PromptHeads } from "../../src/agent-session/acpmux/promptHeads";

const held = new WeakMap<readonly AcpmuxRow[], PromptHeads>();

/// The pane's prompt index of `rows` (the snapshot's `earlierPrompts`, promptHeads.ts), one per list: a test that
/// renders the same list again hands the transcript the same index, as the pane's client does.
export function promptIndexOf(rows: readonly AcpmuxRow[] | undefined): PromptHeads | undefined {
  if (!rows) return undefined;
  const heads = held.get(rows) ?? PromptHeads.fromRows(rows);
  held.set(rows, heads);
  return heads;
}
