export const folderContinuationRequest = { noProject: true, continueWithoutFolder: true } as const;

/** Serializes a no-project recovery and invalidates stale completions when the pane changes. */
export class FolderContinuation {
  private generation = 0;
  private pending = false;
  invalidate(): void { this.generation += 1; }
  async run(actions: {
    start(): Promise<string | undefined>;
    current(): boolean;
    transfer(sessionId: string): { cancel(): void; commit(): Promise<void> };
    select(sessionId: string): Promise<boolean>;
    clearFolder(): void;
  }): Promise<void> {
    if (this.pending) return;
    this.pending = true;
    const generation = this.generation;
    let transfer: { cancel(): void; commit(): Promise<void> } | undefined;
    try {
      const sessionId = await actions.start();
      if (!sessionId || generation !== this.generation || !actions.current()) return;
      transfer = actions.transfer(sessionId);
      if (await actions.select(sessionId)) {
        await transfer.commit();
        actions.clearFolder();
      } else transfer.cancel();
    } catch (error) {
      transfer?.cancel();
      throw error;
    } finally {
      this.pending = false;
    }
  }
}
