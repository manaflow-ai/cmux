import type { AcpmuxActivity, AcpmuxRow } from "../model";

const PREFIX = "test-tampering-turn-";
export const TEST_TAMPERING_TURN = "testTampering";

/** An alarm is a separate transcript row, outside the turn's worked/tool disclosures. */
export const isTestTamperingTurn = (row: AcpmuxRow): boolean => row.kind === TEST_TAMPERING_TURN;

type TurnAlarm = { source: readonly AcpmuxRow[]; row?: AcpmuxRow };
const alarms = new WeakMap<AcpmuxRow, TurnAlarm>();
// Derived rows have no daemon version. Give changed evidence a fresh version even when a prompt
// was replaced with a new object, so transcript row memos cannot retain the old evidence.
let nextVersion = 1;

/** Called only for the turn being shaped, never over the whole transcript. Streaming prose does
 * not revisit reports: only changed activity rows invalidate this turn's cached evidence. */
export function testTamperingTurn(user: AcpmuxRow, source: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  const activity = source.filter((row) => row.kind === "activity");
  const cached = alarms.get(user);
  if (
    cached &&
    activity.length === cached.source.length &&
    activity.every((row, index) => row === cached.source[index])
  )
    return cached.row;

  // One edit call can have several updates in a replay. Its latest status wins, including a
  // failed update: an edit that did not happen must not retain a warning from an earlier update.
  const latest = new Map<string, { row: AcpmuxRow; item: AcpmuxActivity }>();
  for (const row of activity)
    for (const item of row.items ?? []) if (item.tool) latest.set(item.tool.id, { row, item });
  const flagged = [...latest.values()].filter(({ row, item }) => {
    const tool = item.tool!;
    return (
      !row.failed &&
      (tool.kind === "edit" || tool.kind === "fileChange") &&
      tool.status !== "pending" &&
      tool.status !== "failed" &&
      tool.tampering?.files.some((file) => file.findings.length > 0)
    );
  });
  if (flagged.length === 0) {
    alarms.set(user, { source: activity });
    return undefined;
  }

  const first = flagged[0]!.row;
  const turnId = user.turnId ?? first.turnId ?? user.id;
  const items = flagged.map(({ item }) => item);
  const previous = cached?.row;
  if (
    previous &&
    previous.turnId === turnId &&
    previous.at === first.at &&
    previous.seq === first.seq &&
    previous.items?.length === items.length &&
    items.every((item, index) => item === previous.items![index])
  ) {
    alarms.set(user, { source: activity, row: previous });
    return previous;
  }
  const row: AcpmuxRow = {
    id: `${PREFIX}${turnId}`,
    version: nextVersion++,
    kind: TEST_TAMPERING_TURN,
    turnId,
    at: first.at,
    seq: first.seq,
    // Retain the original tool objects, including tamperingEventSeq for exact restore actions.
    items,
    toolCount: items.length,
  };
  alarms.set(user, { source: activity, row });
  return row;
}
