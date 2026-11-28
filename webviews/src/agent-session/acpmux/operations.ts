// acpmux operations the pane uses only when acpmux says it serves them. Names follow the
// operation catalog (cmux-next-spec spec/acp-ui.md, family `acp.*`, owner acpmux).

/// Fork a session through one of its turns: `{ sessionId, throughSeq }` → `{ sessionId }` of
/// the new session, holding the source's events up to and including `throughSeq`.
export const FORK_OP = "acp.session.fork";

/// Whether acpmux's `initialize` result lists `op` among the operations it serves
/// (`_meta.acpmux.operations`). An acpmux that does not list it does not get asked.
export function servesOperation(initialize: unknown, op: string): boolean {
  const operations = (initialize as { _meta?: { acpmux?: { operations?: unknown } } } | undefined)?._meta?.acpmux
    ?.operations;
  return Array.isArray(operations) && operations.includes(op);
}
