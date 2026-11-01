export const folderContinuationRequest = { noProject: true, continueWithoutFolder: true } as const;

/** Serializes a no-project recovery and invalidates stale completions when the pane changes. */
export class FolderContinuation {
  private generation = 0;
  private pending = false;
  invalidate(): void {
    this.generation += 1;
  }
  async run(actions: {
    start(): Promise<string | undefined>;
    current(): boolean;
    copyText(sessionId: string): void;
    select(sessionId: string): Promise<boolean>;
    clearFolder(): void;
  }): Promise<void> {
    if (this.pending) return;
    this.pending = true;
    const generation = this.generation;
    try {
      const sessionId = await actions.start();
      if (!sessionId || generation !== this.generation || !actions.current()) return;
      // Copy only. The source draft, attachments, and pending reads remain owned by their chat.
      actions.copyText(sessionId);
      if ((await actions.select(sessionId)) && generation === this.generation && actions.current())
        actions.clearFolder();
    } finally {
      this.pending = false;
    }
  }
}
