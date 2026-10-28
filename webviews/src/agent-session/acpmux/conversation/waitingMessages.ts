// Several other sessions' messages that wait for the agent draw as one card, not one card each
// (Leo, 2026-10-27: "i also feel like there should be better batching for messages from other
// sessions so you can get to things faster/more efficiently"). Two runs qualify, never mixed:
// - `step`: messages steered into the running turn that the agent has not read yet ("Read after
//   this step"), received rows next to each other among the steers that wait (snapshot
//   `waitingSteers`), grouped as the running turn is drawn (turns.ts `turnViewFrom`);
// - `turn`: messages queued behind the running turn ("Read after this turn"), the transcript's
//   queued tail (queuedMessages.ts), grouped with it (`groupWaitingTurn`).
// A run of two or more becomes one WAITING_MESSAGES row (WaitingMessagesCard.tsx) that holds its
// rows, oldest first; one message alone draws as before. Each message stays its own row inside the
// card, with its own actions; acpmux records each one as before, whether or not it delivers them
// together. The card's row names every row it holds (`joined`), so Find reaches each.
//
// Cost: nothing while fewer than two steers wait and fewer than two messages are queued. The queue's
// card is made once per queue change. The steers' rows are found where the last snapshot had them,
// one lookup each (a new steer looks once), and their cards take their place as the running turn's
// rows are drawn: no pass and no copy of the rows of their own.
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

/// Where the steers that wait were in the running turn's drawn rows last time, and the cards their
/// runs drew as (`groupWaitingSteps`).
export type WaitingSteps = {
  steers: readonly string[];
  /// Each steer's index in the turn's drawn rows, and the steers the turn did not have.
  at: ReadonlyMap<string, number>;
  unseen: ReadonlySet<string>;
  /// Each run of two or more as [first index, end index, card row].
  runs: readonly (readonly [number, number, AcpmuxRow])[];
};

/// The runs of two or more of other sessions' messages among the steers that wait (`steers`,
/// snapshot `waitingSteers`) in the running turn's drawn `rows`, each with its card row, for the
/// turn's rows to draw in their place (turns.ts). Each steer is found where `last` had it, one
/// lookup each; only a steer `last` did not place, or one whose row moved, is looked for, from the
/// turn's end back, once: one the turn does not have stays unseen while `steers` is the same list.
/// `last`'s cards are kept while they hold the same rows.
export function groupWaitingSteps(
  rows: readonly AcpmuxRow[],
  steers: readonly string[],
  last?: WaitingSteps,
): WaitingSteps {
  const same = last?.steers === steers;
  const at = new Map<string, number>();
  const unseen = new Set<string>();
  const sought = new Set<string>();
  for (const id of steers) {
    const index = same ? last!.at.get(id) : undefined;
    if (index !== undefined && rows[index]?.id === id) at.set(id, index);
    else if (same && last!.unseen.has(id)) unseen.add(id);
    else sought.add(id);
  }
  for (let index = rows.length - 1; index >= 0 && sought.size > 0; index -= 1)
    if (sought.delete(rows[index]!.id)) at.set(rows[index]!.id, index);
  for (const id of sought) unseen.add(id);
  const indices = [...at.values()].filter((index) => waitingStep(rows[index]!)).sort((a, b) => a - b);
  const spans: [number, number][] = [];
  for (const index of indices) {
    const span = spans[spans.length - 1];
    if (span && span[1] === index) span[1] = index + 1;
    else spans.push([index, index + 1]);
  }
  const lastCards = new Map(last?.runs.map(([, , card]) => [card.id, card]));
  const runs = spans
    .filter(([from, to]) => to - from >= 2)
    .map(([from, to]) => {
      const members = rows.slice(from, to);
      return [from, to, cardRow("step", members, lastCards.get(`waiting-step-${members[0]!.id}`))] as const;
    });
  return { steers, at, unseen, runs };
}
