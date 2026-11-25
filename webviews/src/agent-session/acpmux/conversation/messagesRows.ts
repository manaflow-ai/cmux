import type { AcpmuxRow } from "../model";

const HIDDEN_INCOMING = "hidden";
const ASK_KINDS = new Set(["permission", "permissionRecord", "question", "questionRecord"]);

/** An ask remains in the message stream only for as long as it needs an answer. */
function pendingAsk(row: AcpmuxRow): boolean {
  if (!ASK_KINDS.has(row.kind)) return false;
  return row.permission?.pending === true || row.question?.state.kind === "pending" || row.pending === true;
}

/**
 * Keep a failed/stopped turn's action card in Messages mode. A successful turn summary is only a
 * worked-for/footer row and is intentionally omitted.
 */
function recoveryRow(row: AcpmuxRow): boolean {
  if (row.kind === "turnSummary") {
    const stopped = row.status === "cancelled" || row.status === "interrupted";
    const failed = row.status === "failed" || row.status === "error";
    if (!stopped && !failed) return false;
    return failed || row.resumable === true;
  }
  return false;
}

function keeps(row: AcpmuxRow): boolean {
  if (pendingAsk(row) || recoveryRow(row)) return true;
  if (row.kind === "assistant") return Boolean(row.text?.trim());
  if (row.kind !== "user") return false;
  // Automatic bookkeeping prompts are represented as hidden user rows. They should not leave an
  // empty bubble. MessageRow also treats these as non-rendering, so keeping one would only leave
  // a blank virtualized row in the Messages stream.
  if (row.incoming?.kind === HIDDEN_INCOMING) return false;
  return true;
}

const cached = new WeakMap<readonly AcpmuxRow[], AcpmuxRow[]>();

/**
 * Select the rows shown by the Messages presentation.
 *
 * The original row objects are returned unchanged so row identity, streaming updates, and action
 * handlers remain valid. The WeakMap cache means a streamed snapshot that reuses its source array
 * does not scan the whole transcript again.
 */
export function messagesRows(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const previous = cached.get(rows);
  if (previous) return previous;

  // Unknown rows are status/plumbing records by default. Messages mode is deliberately a
  // speaker-only view; adding a new row kind must not accidentally expose a tool call.
  const visible = rows.filter(keeps);
  cached.set(rows, visible);
  return visible;
}
