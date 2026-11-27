type ForkRecovery = {
  source?: string;
  target?: string;
  handoffId?: string;
  selectionToken: number;
  currentSelectionToken: () => number;
  currentHandoffId: () => string | undefined;
  selectedSession: () => string | undefined;
  select: (id: string) => Promise<string | undefined>;
  persist: (id: string) => Promise<unknown>;
};

/** Return a failed fork to its source without discarding an uncertain target delivery. */
export async function restoreForkSource(recovery: ForkRecovery): Promise<void> {
  const { source, target, handoffId } = recovery;
  // Start may fail after the user has moved elsewhere. Never move another chat or its handoff.
  if (
    !source ||
    !target ||
    !handoffId ||
    recovery.currentSelectionToken() !== recovery.selectionToken ||
    recovery.currentHandoffId() !== handoffId ||
    recovery.selectedSession() !== target
  )
    return;

  // Selection changes synchronously; attachment can finish later. Preserve navigation that
  // happens during attachment, and retain the target so uncertain delivery can be recovered.
  const attaching = recovery.select(source);
  const selectionToken = recovery.currentSelectionToken();
  const selected = await attaching;
  if (
    selected === source &&
    recovery.selectedSession() === source &&
    recovery.currentSelectionToken() === selectionToken
  )
    await recovery.persist(source);
}
