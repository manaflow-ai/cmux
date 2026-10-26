import type { AcpmuxSnapshot } from "../model";

/// A local folder panel can outlive its chat or a machine move. Never send its result to a
/// different environment; cancellation keeps the current chat exactly where it is.
export async function chooseEnvironmentFolder(
  before: AcpmuxSnapshot,
  browse: () => Promise<string | undefined>,
  current: () => AcpmuxSnapshot | undefined,
  open: (cwd: string) => void,
): Promise<void> {
  const local = (snapshot: AcpmuxSnapshot) =>
    snapshot.summary &&
    !snapshot.summary.peer &&
    (!snapshot.summary.hostKind || snapshot.summary.hostKind === "local") &&
    (!snapshot.summary.host || snapshot.summary.hostKind === "local");
  if (!before.sessionId || !local(before)) return;
  const cwd = await browse();
  const after = current();
  if (
    cwd &&
    after &&
    after.sessionId === before.sessionId &&
    local(after) &&
    after.summary?.host === before.summary?.host &&
    after.summary?.cwd === before.summary?.cwd
  )
    open(cwd);
}
