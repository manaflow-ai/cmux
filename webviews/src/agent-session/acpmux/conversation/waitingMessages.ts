// Several other sessions' messages that wait for the agent draw as one card, not one card each
// (Leo, 2026-10-27: "i also feel like there should be better batching for messages from other
// sessions so you can get to things faster/more efficiently"). Two runs qualify, never mixed:
// - `step`: messages steered into the running turn that the agent has not read yet ("Read after
//   this step"), received rows next to each other among the steers that wait (snapshot
//   `waitingSteers`), grouped in the transcript (`groupWaitingSteps`);
// - `turn`: messages queued behind the running turn ("Read after this turn"), the transcript's
//   queued tail (queuedMessages.ts), grouped with it (`groupWaitingTurn`).
// A run of two or more becomes one WAITING_MESSAGES row (WaitingMessagesCard.tsx) that holds its
// rows, oldest first; one message alone draws as before. Each message stays its own row inside the
// card, with its own actions; acpmux records each one as before, whether or not it delivers them
// together. The card's row names every row it holds (`joined`), so Find reaches each.
//
// Cost: nothing while fewer than two steers wait and fewer than two messages are queued. The queue's
// card is made once per queue change. The steers' rows are found where the last snapshot had them,
// one lookup each; only a new steer, or rows that moved above them (an older page), looks for them
// from the end back to the running turn's start, once. While a card shows, the drawn rows are a
// copy of the rows with the card in its run's place.
import { QUEUED_MESSAGE, WAITING_MESSAGES, type AcpmuxRow } from "../model";

/// Whether `row` is another session's message that waits for the agent's current step.
const waitingStep = (row: AcpmuxRow) =>
  row.kind === "user" && row.steer === "waiting" && row.incoming?.kind === "message";

// A card row's version counts every card made, so a card that comes back under the same id never
// reads as one drawn before.
let version = 0;

/// The card row of `members` (two or more): `before` when it is that card and holds the same rows.
function cardRow(delivery: "step" | "turn", members: readonly AcpmuxRow[], before: AcpmuxRow | undefined): AcpmuxRow {
  // Named by its first message, so a later card never takes an earlier one's open state.
  const id = `waiting-${delivery}-${members[0]!.id}`;
  const held = before?.id === id ? before.waiting?.rows : undefined;
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

/// The queued tail as drawn: one card when two or more of other sessions' messages wait, else
/// `tail` itself. `last`: the previous result, given back while it holds the same rows.
export function groupWaitingTurn(tail: readonly AcpmuxRow[], last?: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  if (tail.length < 2 || !tail.every((row) => row.kind === QUEUED_MESSAGE)) return tail;
  const before = last?.length === 1 && last[0]!.kind === WAITING_MESSAGES ? last[0] : undefined;
  const card = cardRow("turn", tail, before);
  return card === before ? last! : [card];
}

/// The rows as drawn, the card rows among them by id, and where the steers' rows were.
export type WaitingSteps = {
  rows: AcpmuxRow[];
  cards?: ReadonlyMap<string, AcpmuxRow>;
  /// The steers looked for (`steers`), the index of each one found, and the ones not there.
  steers?: readonly string[];
  at?: ReadonlyMap<string, number>;
  unseen?: ReadonlySet<string>;
};

/// Each steer's row index in `rows`: where `last` had it while that row is still there, else looked
/// for from the end (before the `tail` rows) back to the running turn's start (the previous turn's
/// footer). One `last` could not find stays unseen while the steers are the same list.
function steerRows(rows: readonly AcpmuxRow[], steers: readonly string[], tail: number, last?: WaitingSteps) {
  const at = new Map<string, number>();
  const unseen = new Set<string>();
  const sought = new Set<string>();
  for (const id of steers) {
    const index = last?.at?.get(id);
    if (index !== undefined && rows[index]?.id === id) at.set(id, index);
    else if (last?.steers === steers && last.unseen?.has(id)) unseen.add(id);
    else sought.add(id);
  }
  for (let index = rows.length - 1 - tail; index >= 0 && sought.size > 0; index -= 1) {
    const row = rows[index]!;
    if (row.kind === "turnSummary") break;
    if (!sought.delete(row.id)) continue;
    at.set(row.id, index);
  }
  for (const id of sought) unseen.add(id);
  return { at, unseen };
}

/// `rows` with each run of two or more of other sessions' messages among the steers that wait
/// (`steers`, snapshot `waitingSteers`) as one card row. `tail`: how many rows at the end are the
/// queued tail, where no steer is. `last`: the previous result, whose card rows are kept while they
/// hold the same rows. `rows` comes back as it is when no run qualifies.
export function groupWaitingSteps(
  rows: AcpmuxRow[],
  steers: readonly string[] | undefined,
  tail = 0,
  last?: WaitingSteps,
): WaitingSteps {
  if (!steers || steers.length < 2) return { rows };
  const { at, unseen } = steerRows(rows, steers, tail, last);
  const indices = [...at.values()].filter((index) => waitingStep(rows[index]!)).sort((a, b) => a - b);
  const runs: [number, number][] = [];
  for (const index of indices) {
    const run = runs[runs.length - 1];
    if (run && run[1] === index) run[1] = index + 1;
    else runs.push([index, index + 1]);
  }
  const grouped = runs.filter(([from, to]) => to - from >= 2);
  if (!grouped.length) return { rows, steers, at, unseen };
  const cards = new Map<string, AcpmuxRow>();
  const next = [...rows];
  // Spliced from the last run back, so the earlier runs keep their places.
  for (const [from, to] of grouped.reverse()) {
    const members = rows.slice(from, to);
    const card = cardRow("step", members, last?.cards?.get(`waiting-step-${members[0]!.id}`));
    cards.set(card.id, card);
    next.splice(from, to - from, card);
  }
  return { rows: next, cards, steers, at, unseen };
}
