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
// card is made once per queue change. The steers' cards are made as the running turn's rows are
// drawn, which every snapshot of a running turn does already: one pass over that turn's rows, never
// the chat's.
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

/// A turn's drawn `rows` with each run of two or more of other sessions' messages among the steers
/// that wait (`steers`, snapshot `waitingSteers`) as one card row, and those cards by id. `last`:
/// the previous cards, each kept while it holds the same rows. `rows` comes back as it is when no
/// run qualifies.
export function groupWaitingSteps(
  rows: readonly AcpmuxRow[],
  steers: ReadonlySet<string>,
  last?: ReadonlyMap<string, AcpmuxRow>,
): { rows: readonly AcpmuxRow[]; cards?: ReadonlyMap<string, AcpmuxRow> } {
  const runs: [number, number][] = [];
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (!steers.has(row.id) || !waitingStep(row)) continue;
    const run = runs[runs.length - 1];
    if (run && run[1] === index) run[1] = index + 1;
    else runs.push([index, index + 1]);
  }
  const grouped = runs.filter(([from, to]) => to - from >= 2);
  if (!grouped.length) return { rows };
  const cards = new Map<string, AcpmuxRow>();
  const out: AcpmuxRow[] = [];
  let from = 0;
  for (const [start, end] of grouped) {
    for (let index = from; index < start; index += 1) out.push(rows[index]!);
    const members = rows.slice(start, end);
    const card = cardRow("step", members, last?.get(`waiting-step-${members[0]!.id}`));
    cards.set(card.id, card);
    out.push(card);
    from = end;
  }
  for (let index = from; index < rows.length; index += 1) out.push(rows[index]!);
  return { rows: out, cards };
}
