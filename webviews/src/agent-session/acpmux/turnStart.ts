// Where a turn starts in the client's rows. A prompt opens a turn; a steer (a prompt sent into the
// running turn, or one sent now that stopped it and runs next) goes on with the turn it went into,
// so everything that finds a turn by its prompt walks past it: the transcript's turns
// (conversation/turns.ts), a turn's edits and checkpoint (diff.ts), Find, the minimap, running
// subagent groups. A leaf module, so each of those can import it.
import type { AcpmuxRow } from "./model";

/// A prompt that goes on with the turn it was sent into, rather than opening one: the transcript
/// draws it inline in that turn, and the turn's clock runs from its first prompt.
export const continuesTurn = (row: AcpmuxRow): boolean =>
  row.kind === "user" && (row.steer !== undefined || row.continues === true) && !row.pending && !row.failed;

/// A row that opens a turn: a prompt that is not a steer.
export const opensTurn = (row: AcpmuxRow): boolean => row.kind === "user" && !continuesTurn(row);
