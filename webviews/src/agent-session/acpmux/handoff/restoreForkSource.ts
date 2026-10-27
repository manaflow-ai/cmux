type ForkRecovery = {
  source?: string;
  target?: string;
  handoffId?: string;
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
    recovery.currentHandoffId() !== handoffId ||
    recovery.selectedSession() !== target
  )
    return;

  // Selection changes synchronously; attachment can finish later. Preserve navigation that
  // happens during attachment, and retain the target so uncertain delivery can be recovered.
  const selected = await recovery.select(source);
  if (selected === source && recovery.selectedSession() === source) await recovery.persist(source);
}
