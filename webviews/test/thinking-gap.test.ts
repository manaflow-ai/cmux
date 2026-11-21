// The running turn's Thinking line sits one gap under the last row that takes room (T4, Leo 2026-11-21:
// "we can't afford to have these thrown together"): 8 under a step or status row (variant B, the live
// line's gap, transcriptGrid.ts TRANSCRIPT_LIVE_STEP_GAP; Leo 05:23Z: "see the space/gap between tool
// calls and the current shimmer? this isnt great."), 8 under a reply,
// 24 under a prompt or steer. A pure sweep: each step of seeded coordinator turns through turnViewFrom
// and layoutConversation; thinking-gap-browser.test.ts reads the same scenes drawn, frame by frame.
import { describe, expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import { projectInboxRows } from "../src/agent-session/acpmux/conversation/laneNoticeBatches";
import { mergeInboxNotices } from "../src/agent-session/acpmux/conversation/inboxNotice";
import { pendingMessagesRow, withWaitingRows } from "../src/agent-session/acpmux/conversation/pendingMessages";
import { subagentRowsFrom } from "../src/agent-session/acpmux/subagents/subagentRows";
import { TRANSCRIPT_LIVE_STEP_GAP } from "../src/agent-session/acpmux/transcriptGrid";
import { playTurn, randomTurn, type GapEvent } from "./support/thinkingGapScenes";

const MAX_GAP = 24;

/// The rows the pane draws for `raw` (test/browser/thinking-gap.harness.tsx `shape`).
function shaped(raw: AcpmuxRow[]): AcpmuxRow[] {
  const turns = turnViewFrom(raw, new Set(), { working: true, agentFamily: "claude" });
  const rows = subagentRowsFrom(projectInboxRows(turns.rows), new Set()).rows;
  const group = pendingMessagesRow(turns.pending ?? [], [], undefined);
  return withWaitingRows(mergeInboxNotices([...rows]), group ? [group] : []);
}

/// The Thinking line's distance from the bottom of the last row over it that takes room.
function lineGap(raw: AcpmuxRow[]): { gap: number; above: string; between: string[] } | undefined {
  const rows = shaped(raw);
  const layout = layoutConversation(rows, 800);
  const line = rows.findIndex((row) => row.id === "thinking-live");
  if (line < 0) return undefined;
  let above = line - 1;
  while (above >= 0 && layout.heights[above] === 0) above -= 1;
  if (above < 0) return undefined;
  return {
    gap: layout.tops[line]! - (layout.tops[above]! + layout.heights[above]!),
    above: `${rows[above]!.id}/${rows[above]!.kind}`,
    between: rows.slice(above + 1, line).map((row) => `${row.id}/${row.kind}`),
  };
}

function overs(events: GapEvent[]): string[] {
  const out: string[] = [];
  for (const step of playTurn(events)) {
    const found = lineGap(step.rows);
    if (found && found.gap > MAX_GAP)
      out.push(`${step.name}: ${found.gap} under ${found.above} past ${found.between.join(",")}`);
  }
  return out;
}

describe("the Thinking line's gap, as laid out", () => {
  test("Leo's scene: a closed run, then thought and command rows, Thinking one live-step gap under the last", () => {
    const steps = playTurn([
      { kind: "message" },
      ...Array.from({ length: 3 }, (): GapEvent[] => [{ kind: "tool" }, { kind: "finish" }]).flat(),
      ...Array.from({ length: 3 }, (): GapEvent[] => [
        { kind: "thought" },
        { kind: "thought", ended: true },
        { kind: "tool" },
        { kind: "finish" },
      ]).flat(),
    ]);
    expect(lineGap(steps.at(-1)!.rows)?.gap).toBe(TRANSCRIPT_LIVE_STEP_GAP);
    expect(TRANSCRIPT_LIVE_STEP_GAP).toBe(8);
  });

  // Seed 2, step 32: a steer, then a thought, then a new call. The run holding the thought draws
  // nothing (the call is on the live line), yet it marks the line a step's live line (MARK_LIVE_STEP), and
  // the gap is taken from the steer: transcriptGap(PROMPT, LIVE_STEP) = the turn gap, 32, not 24.
  test("a run that draws nothing between a steer and the line leaves the prompt's gap", () => {
    expect(overs(randomTurn(2, 40))).toEqual([]);
  });

  test("seeded coordinator turns: never more than a block gap", () => {
    const all: string[] = [];
    for (let seed = 1; seed <= 40; seed += 1)
      for (const over of overs(randomTurn(seed, 60))) all.push(`seed ${seed} ${over}`);
    expect(all).toEqual([]);
  });
});
