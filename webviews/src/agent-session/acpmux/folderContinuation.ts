export const folderContinuationRequest = { noProject: true, continueWithoutFolder: true } as const;

/** Serializes a no-project recovery and invalidates stale completions when the pane changes. */
export type DraftTransfer = { ready: Promise<void>; cancel(): void; commit(): void };

export class FolderContinuation {
  private generation = 0;
  private pending = false;
  invalidate(): void { this.generation += 1; }
  async run(actions: {
    start(): Promise<string | undefined>;
    current(): boolean;
    transfer(sessionId: string): DraftTransfer;
    select(sessionId: string): Promise<boolean>;
    clearFolder(): void;
  }): Promise<void> {
    if (this.pending) return;
    this.pending = true;
    const generation = this.generation;
    let transfer: DraftTransfer | undefined;
    try {
      const sessionId = await actions.start();
      if (!sessionId || generation !== this.generation || !actions.current()) return;
      transfer = actions.transfer(sessionId);
      await transfer.ready;
      if (generation !== this.generation || !actions.current()) {
        transfer.cancel();
        return;
      }
      if (await actions.select(sessionId)) {
        transfer.commit();
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
