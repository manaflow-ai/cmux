/// A Cloud chat's hand-off turns (cloud work mode, leo-workspace design/cloud-work-mode.md): the
/// owner side. Before a prompt that starts a turn goes to a chat on a Cloud machine, the page asks
/// the app to open the chat's hand-off turn (`cloud.handoffTurn {sessionId}`). The app creates the
/// session's hand-off on its first turn (`POST /v1/handoffs`), or begins the next turn once the last
/// one ended (`POST /v1/handoffs/:id/turns`), and answers the turn's number. The prompt then goes
/// with the id `handoff-<turn>-<id>`: acpmux on the machine reports that turn's running, needs-you,
/// done or failed to the hand-off by the number its prompt names (cmux-tui acpmux
/// `daemon/cloud_handoff.rs` `named_turn`), and the app's watcher tells the person.
///
/// Only an app that says it opens hand-off turns (`cloudHandoffs` in its `ready` reply) is asked,
/// and only for a chat on a Cloud machine (`cloudMachineID`). No answer (an app that refuses, a turn
/// still running, the store unreachable, or no answer within ``TURN_WAIT_MS``) sends the prompt
/// under its own id: it runs as before, and only its report is missing.

/// The prompt id's prefix acpmux reads (`cloud_handoff.rs` `PROMPT_PREFIX`).
export const HANDOFF_PROMPT_PREFIX = "handoff-";
/// The longest a send waits for the app to open its turn.
export const TURN_WAIT_MS = 2_500;

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// The turn's number from the app's answer: a whole number from 1, at most 15 digits (acpmux reads
/// no longer one), else none.
export function turnOf(reply: unknown): number | undefined {
  const turn = (reply as { turn?: unknown } | null | undefined)?.turn;
  return typeof turn === "number" && Number.isSafeInteger(turn) && turn >= 1 && turn < 1e15 ? turn : undefined;
}

/// The id a prompt of hand-off turn `turn` goes with: the turn, then the prompt's own id, so the
/// row, the delivery and a gesture ticket bound to that id still name the same prompt.
export function handoffPromptId(turn: number, promptId: string): string {
  return `${HANDOFF_PROMPT_PREFIX}${turn}-${promptId}`;
}

/// Asks the app to open session `sessionId`'s hand-off turn; its number, or undefined when there is
/// none to name (refused, failed, or not answered in time). Never rejects.
export function openHandoffTurn(call: Call, sessionId: string, waitMs = TURN_WAIT_MS): Promise<number | undefined> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<undefined>((resolve) => {
    timer = setTimeout(() => resolve(undefined), waitMs);
  });
  const asked = call("cloud.handoffTurn", { sessionId }).then(turnOf, () => undefined);
  return Promise.race([asked, late]).finally(() => clearTimeout(timer));
}

/// The ask a chat's page uses, or none: only an app that opens hand-off turns, for a chat on one of
/// the account's Cloud machines.
export function handoffTurns(
  call: Call,
  host: { cloudHandoffs?: unknown; cloudMachineID?: unknown },
): ((sessionId: string) => Promise<number | undefined>) | undefined {
  if (host.cloudHandoffs !== true || typeof host.cloudMachineID !== "string" || !host.cloudMachineID) return undefined;
  return (sessionId) => openHandoffTurn(call, sessionId);
}
