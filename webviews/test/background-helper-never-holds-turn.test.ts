// l10n-allow-file: test fixture subagent names, not shipped UI.
// Leo, 2026-11-12, on "Waiting on 16 subagents 14m 24s" under a turn whose helpers all ran in the
// background: "this is taking a REALLY long time? shouldn't this have backgrounded?". A helper met
// first through its progress (its spawn on a page the pane never read) joins the running turn's
// group, so it counted as one the turn waits on unless the event said it was background. acpmux
// now marks every event of background work, a background helper's own subagents too
// (subagents.rs `mark_background_work`); this is the pane's side of that contract.
import { expect, test } from "bun:test";
import { SubagentFold } from "../src/agent-session/acpmux/subagents/subagentFold";
import { trayWaitAgents } from "../src/agent-session/acpmux/conversation/turns";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const update = (update: Record<string, unknown>, acpmux: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update, _meta: { acpmux } },
});
let seq = 0;
const feed = (fold: SubagentFold, at: number, msg: ReturnType<typeof update>) => {
  seq += 1;
  fold.reduce({ seq, at, msg }, msg.params.update);
};
const progress = (id: string, background?: true) =>
  update(
    { sessionUpdate: "subagent_progress" },
    { subagents: [{ id, parent: null, state: "running", name: id, ...(background && { background }) }] },
  );
const prompt: AcpmuxRow = { id: "u1", kind: "user", text: "Fan out", at: 0, version: 1 } as AcpmuxRow;
const waits = (fold: SubagentFold) => trayWaitAgents([prompt, ...fold.takeRows()]);

test("helpers met through their progress, marked background, hold no wait on the turn", () => {
  const fold = new SubagentFold();
  fold.startTurn();
  for (let n = 0; n < 16; n += 1) feed(fold, 1_000 + n, progress(`acp-1/toolu_${n}`, true));
  expect(fold.all().filter((agent) => agent.state === "running")).toHaveLength(16);
  expect(waits(fold)).toBe(0);
});

test("a foreground subagent met the same way is still waited on", () => {
  const fold = new SubagentFold();
  fold.startTurn();
  feed(fold, 1_000, progress("acp-1/toolu_fg"));
  feed(fold, 1_001, progress("acp-1/toolu_bg", true));
  expect(waits(fold)).toBe(1);
});
