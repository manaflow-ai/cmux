// l10n-allow-file: test of gallery fixtures.
// Each received message is named once (Leo, 2026-11-17, on "Received 2 messages" over "Working for
// 15s" and a second "Received 2 messages" under it: "1 me 2 austin we sometimes have weird ui like
// this"). The turn two messages opened: its inbox notice is the prompt, and the agent then got each
// message on its own line beside a run of no work the line names (a thought and a hidden ToolSearch).
// The run's line (messageRuns.ts) folded those lines away, so the turn's "Received N messages" row
// (laneNoticeBatches.ts) could not see them and named both messages again.
import { expect, test } from "bun:test";
import { foldMessageRuns } from "../src/agent-session/acpmux/conversation/messageRuns";
import { projectInboxRows } from "../src/agent-session/acpmux/conversation/laneNoticeBatches";
import { inboxTurn } from "../src/agent-session/acpmux/conversation/TurnBoundaryGaps.gallery";
import { LANE_NOTICE_BATCH, MESSAGE_RUN, type AcpmuxRow } from "../src/agent-session/acpmux/model";

const NONE = new Set<string>();

/// The turn's rows as its shaping leaves them: the notice that opened it, then its body with the
/// earlier run folded (turns.ts `earlierRun` marks it `foldRun`).
function turn(items?: (row: AcpmuxRow) => AcpmuxRow["items"]) {
  const [notice, coord, arch, search] = inboxTurn(false).slice(3, 7) as [AcpmuxRow, AcpmuxRow, AcpmuxRow, AcpmuxRow];
  const run = { ...search, foldRun: true, ...(items && { items: items(search) }) };
  return { notice, body: [coord, arch, run] };
}

/// How many messages the drawn rows name: a "Received N messages" row its N, a run's line its
/// received count, a message's own line one, an inbox notice drawn whole its threads.
function named(rows: readonly AcpmuxRow[]): number {
  let total = 0;
  for (const row of rows) {
    if (row.kind === MESSAGE_RUN) total += row.messageRun?.received ?? 0;
    else if (row.kind === LANE_NOTICE_BATCH) total += row.laneNoticeBatch?.rows.length ?? 0;
    else if (row.incoming?.kind === "inbox") total += row.incoming.notice.threads.length;
    else if (row.incoming?.kind === "message") total += 1;
  }
  return total;
}

test("a run of received lines beside a thought names each message once with the turn's notice", () => {
  const { notice, body } = turn();
  const drawn = projectInboxRows([notice, ...foldMessageRuns(body, NONE)]);
  expect(named(drawn)).toBe(2);
});

test("a run of only hidden calls between received lines is no work: they draw in the Received row", () => {
  const { notice, body } = turn((search) => search.items!.filter((item) => item.kind === "tool"));
  const folded = foldMessageRuns(body, NONE);
  expect(folded.some((row) => row.kind === MESSAGE_RUN)).toBe(false);
  const drawn = projectInboxRows([notice, ...folded]);
  expect(named(drawn)).toBe(2);
  expect(drawn.filter((row) => row.kind === LANE_NOTICE_BATCH)).toHaveLength(1);
});

test("an inbox notice and the lines that delivered its messages count each message once", () => {
  const { notice, body } = turn();
  const [line] = foldMessageRuns([notice, ...body], NONE);
  expect(line?.kind).toBe(MESSAGE_RUN);
  expect(line?.messageRun?.received).toBe(2);
});
