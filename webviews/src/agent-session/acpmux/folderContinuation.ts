export const folderContinuationRequest = { noProject: true, continueWithoutFolder: true } as const;

/** Serializes a no-project recovery and invalidates stale completions when the pane changes. */
export class FolderContinuation {
  private generation = 0;
  private pending = false;
  invalidate(): void { this.generation += 1; }
  async run(actions: {
    start(): Promise<string | undefined>;
    current(): boolean;
    transfer(sessionId: string): () => void;
    select(sessionId: string): Promise<boolean>;
    clearFolder(): void;
  }): Promise<void> {
    if (this.pending) return;
    this.pending = true;
    const generation = this.generation;
    let cancel: (() => void) | undefined;
    try {
      const sessionId = await actions.start();
      if (!sessionId || generation !== this.generation || !actions.current()) return;
      cancel = actions.transfer(sessionId);
      if (await actions.select(sessionId)) actions.clearFolder();
      else cancel();
    } catch (error) {
      cancel?.();
      throw error;
    } finally {
      this.pending = false;
    }
  }
}
