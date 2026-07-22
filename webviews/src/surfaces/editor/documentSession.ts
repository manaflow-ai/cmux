/**
 * Pure disk-sync state for the code editor surface.
 *
 * The webview owns the live buffer; Swift owns the file. This class tracks the
 * last content both sides agreed on (`baseline`) and decides what an external
 * disk change means for the buffer:
 *
 * - incoming equals the buffer → both sides already agree; nothing to do
 * - buffer is clean → silently replace it with the disk content
 * - buffer is dirty → keep the buffer and surface a conflict banner; the
 *   baseline still moves to the disk content so "dirty" always means
 *   "differs from what is on disk"
 */

export type ExternalChangeAction =
  | { kind: "none" }
  | { kind: "replaceBuffer"; content: string }
  | { kind: "showConflict" };

export class DocumentSession {
  private baseline: string;
  private pendingConflict = false;

  constructor(initialContent: string) {
    this.baseline = initialContent;
  }

  isDirty(currentContent: string): boolean {
    return currentContent !== this.baseline;
  }

  hasPendingConflict(): boolean {
    return this.pendingConflict;
  }

  /** Latest known disk content. */
  diskContent(): string {
    return this.baseline;
  }

  applyExternal(currentContent: string, incomingDiskContent: string): ExternalChangeAction {
    const wasClean = currentContent === this.baseline;
    this.baseline = incomingDiskContent;
    if (incomingDiskContent === currentContent) {
      this.pendingConflict = false;
      return { kind: "none" };
    }
    if (wasClean) {
      this.pendingConflict = false;
      return { kind: "replaceBuffer", content: incomingDiskContent };
    }
    this.pendingConflict = true;
    return { kind: "showConflict" };
  }

  noteSaved(savedContent: string): void {
    this.baseline = savedContent;
    this.pendingConflict = false;
  }

  /** Conflict banner "Reload from disk": returns the content to load into the buffer. */
  resolveConflictReload(): string {
    this.pendingConflict = false;
    return this.baseline;
  }

  /** Conflict banner "Keep my changes": buffer stays; it remains dirty vs. disk. */
  resolveConflictKeepMine(): void {
    this.pendingConflict = false;
  }
}
