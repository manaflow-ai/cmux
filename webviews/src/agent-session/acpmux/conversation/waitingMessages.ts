// Several other sessions' messages that wait for the agent draw as one card, not one card each
// (Leo, 2026-10-27: "i also feel like there should be better batching for messages from other
// sessions so you can get to things faster/more efficiently"). Two runs qualify, never mixed:
// - `step`: messages steered into the running turn that the agent has not read yet ("Read after
//   this step"), received rows next to each other among the steers that wait (snapshot
//   `waitingSteers`);
// - `turn`: messages queued behind the running turn ("Read after this turn"), the transcript's
//   queued tail (queuedMessages.ts).
// A run of two or more becomes one WAITING_MESSAGES row (WaitingMessagesCard.tsx) that holds its
// rows, oldest first; one message alone draws as before. Each message stays its own row inside the
// card, with its own actions; acpmux records each one as before, whether or not it delivers them
// together. The card's row names every row it holds (`joined`), so Find reaches each.
//
// Cost: nothing while fewer than two steers wait and fewer than two messages are queued. Otherwise
// the steers are looked for from the end of the rows back to the running turn's start, and the
// queued tail is the rows' end.
import { QUEUED_MESSAGE, WAITING_MESSAGES, type AcpmuxRow } from "../model";

/// Whether `row` is another session's message that waits for the agent's current step.
const waitingStep = (row: AcpmuxRow, steers: ReadonlySet<string>) =>
  row.kind === "user" && row.steer === "waiting" && row.incoming?.kind === "message" && steers.has(row.id);

// A card row's version counts every card made, so a card that comes back under the same id never
// reads as one drawn before.
let version = 0;

/// The card row of `members` (two or more), the one from `last` when it holds the same rows.
function cardRow(
  delivery: "step" | "turn",
  members: readonly AcpmuxRow[],
  last: ReadonlyMap<string, AcpmuxRow>,
): AcpmuxRow {
  const id = delivery === "turn" ? "waiting-turn" : `waiting-step-${members[0]!.id}`;
  const before = last.get(id);
  const held = before?.waiting?.rows;
  if (held && held.length === members.length && held.every((row, index) => row === members[index])) return before!;
  const end = members[members.length - 1]!;
  return {
    id,
    version: ++version,
    at: members[0]!.at,
    kind: WAITING_MESSAGES,
    text: members
      .map((row) => (row.incoming?.kind === "message" ? row.incoming.message.text : (row.text ?? "")))
      .join("\n\n"),
    untyped: true,
    joined: members.map((row) => row.id),
    waiting: { delivery, rows: members },
    ...(end.lastTurn ? { lastTurn: end.lastTurn } : {}),
  };
}

/// The rows as drawn, their queued tail, and the card rows among them by id.
export type WaitingGroups = { rows: AcpmuxRow[]; tail?: readonly AcpmuxRow[]; cards?: ReadonlyMap<string, AcpmuxRow> };

/// `rows` (ending with the queued `tail`) with each run of two or more waiting messages as one card
/// row. `steers`: the rows of the steers that wait (snapshot `waitingSteers`). `last`: the previous
/// result, whose card rows are kept while they hold the same rows. The same input gives `rows` and
/// `tail` back unchanged when no run qualifies.
export function groupWaitingMessages(
  rows: AcpmuxRow[],
  tail: readonly AcpmuxRow[] | undefined,
  steers: readonly string[] | undefined,
  last?: WaitingGroups,
): WaitingGroups {
  const queued = tail && tail.length >= 2 && rows[rows.length - 1] === tail[tail.length - 1] ? tail : undefined;
  if (!queued && (steers?.length ?? 0) < 2) return { rows, tail };
  const before = last?.cards ?? new Map<string, AcpmuxRow>();
  const cards = new Map<string, AcpmuxRow>();
  const card = (delivery: "step" | "turn", members: readonly AcpmuxRow[]) => {
    const row = cardRow(delivery, members, before);
    cards.set(row.id, row);
    return row;
  };
  const end = queued ? rows.length - queued.length : rows.length;
  let out = rows;
  let outTail = tail;
  if (queued && queued.every((row) => row.kind === QUEUED_MESSAGE)) {
    outTail = [card("turn", queued)];
    out = [...rows.slice(0, end), ...outTail];
  }
  if ((steers?.length ?? 0) >= 2) {
    const waiting = new Set(steers);
    // From the end back to the running turn's start (the previous turn's footer): the steers that
    // wait are all in the running turn.
    const runs: [number, number][] = [];
    let found = 0;
    for (let index = end - 1; index >= 0 && found < waiting.size; index -= 1) {
      const row = rows[index]!;
      if (row.kind === "turnSummary") break;
      if (!waiting.has(row.id)) continue;
      found += 1;
      if (!waitingStep(row, waiting)) continue;
      const run = runs[runs.length - 1];
      if (run && run[0] === index + 1) run[0] = index;
      else runs.push([index, index + 1]);
    }
    const grouped = runs.filter(([from, to]) => to - from >= 2);
    if (grouped.length) {
      const next = out === rows ? [...rows] : [...out];
      // Spliced from the last run back, so the earlier runs keep their places.
      for (const [from, to] of grouped) next.splice(from, to - from, card("step", rows.slice(from, to)));
      out = next;
    }
  }
  if (out === rows && outTail === tail) return { rows, tail };
  return { rows: out, tail: outTail, cards };
}
