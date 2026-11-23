export const folderContinuationRequest = { noProject: true, continueWithoutFolder: true } as const;
/// The same recovery in the declined folder itself, read-only (acpmux `_meta.acpmux.restricted`,
/// hub/restricted.rs): the folder's settings, hooks and MCP servers stay off and edits are denied.
export const readOnlyContinuationRequest = { continueReadOnly: true } as const;
/// Whether a chat of `family` can continue read-only: acpmux keeps a declined folder's config off
/// only for Claude Code; Codex reads its project config by its own trust record, so acpmux refuses
/// it (`restricted.unsupported`) and the pane offers only the folder-free chat.
export function readOnlyHarness(family: unknown): boolean {
  return family === "claude";
}

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
    /// Ends a session this run started but no longer owns, so none runs with no tab.
    discard?(sessionId: string): void;
  }): Promise<void> {
    if (this.pending) return;
    this.pending = true;
    const generation = this.generation;
    try {
      const sessionId = await actions.start();
      if (!sessionId) return;
      if (generation !== this.generation || !actions.current()) {
        actions.discard?.(sessionId);
        return;
      }
      // Copy only. The source draft, attachments, and pending reads remain owned by their chat.
      actions.copyText(sessionId);
      if ((await actions.select(sessionId)) && generation === this.generation && actions.current())
        actions.clearFolder();
    } finally {
      this.pending = false;
    }
  }
}
