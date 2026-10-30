// l10n-allow-file: latency fixture prompts and replies, not shipped UI.
// The chat transcript with its prompt rail (the thread minimap harness, test/browser/), seeded with a
// 120-turn chat of uneven turn heights, for the latency harness's rail actions (actions.ts): the
// hover card's open and a click's landing.
import "../browser/thread-minimap.harness";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";

const TURNS = 120;
const paragraph = "The answer goes on for a while so the turn has real height in the transcript, as replies do.";
const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}) =>
  ({ id, kind, text, version: 1, at: 1, ...extra }) as unknown as AcpmuxRow;
const rows = Array.from({ length: TURNS }, (_, index) => [
  row(`t${index}-user`, "user", `Prompt number ${index + 1}: look at part ${index + 1} of the plan.`),
  row(
    `t${index}-answer`,
    "assistant",
    Array.from({ length: 1 + ((index * 7) % 5) * 2 }, () => paragraph).join("\n\n"),
  ),
  row(`t${index}-end`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
]).flat();
(window as unknown as { __showRows: (rows: AcpmuxRow[]) => void }).__showRows(rows);
