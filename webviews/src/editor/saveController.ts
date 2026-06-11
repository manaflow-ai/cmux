/**
 * Dirty tracking + save state machine for the Monaco editor surface.
 *
 * The controller owns the editor's save lifecycle: it tracks whether the
 * buffer diverged from the last content synced with disk (via Monaco's
 * alternative version ids), serializes save requests through the native
 * bridge, and models disk conflicts explicitly so a stale buffer never
 * silently clobbers the file.
 *
 * Conflict semantics: every save carries the SHA-256 baseline of the content
 * the buffer was last synced from (initially computed by `cmux edit` over the
 * bytes it inlined into the page; updated from each save reply). The Swift
 * side compares that baseline against the bytes currently on disk and refuses
 * the write on mismatch, replying with the disk content so the user can pick
 * "overwrite" (force save) or "use disk version" (replace the buffer).
 */

export type EditorSaveBridgeReply =
  | { status: "saved"; sha256: string }
  | { status: "conflict"; fileMissing?: boolean; diskSha256?: string; diskContent?: string }
  | { status: "error"; code?: string; detail?: string };

export type EditorSaveRequest = {
  content: string;
  expectedSha256: string | null;
  force: boolean;
};

export type EditorSaveBridge = (request: EditorSaveRequest) => Promise<EditorSaveBridgeReply>;

export type EditorSaveConflict = {
  fileMissing: boolean;
  diskSha256?: string;
  diskContent?: string;
};

export type EditorSaveState = {
  dirty: boolean;
  status: "idle" | "saving" | "saved" | "error";
  errorCode?: string;
  errorDetail?: string;
  conflict: EditorSaveConflict | null;
};

/** The editor buffer the controller saves; backed by the live Monaco model. */
export type EditorSaveDocument = {
  getValue: () => string;
  getVersionId: () => number;
  /** Replaces the buffer content and returns the new version id. */
  replaceWith: (content: string) => number;
};

/**
 * Maps a raw `{ok, value} | {ok, error}` native bridge reply (the shared
 * WKScriptMessageHandlerWithReply envelope) to a typed save reply.
 */
export function mapEditorSaveReply(raw: unknown): EditorSaveBridgeReply {
  if (typeof raw !== "object" || raw === null) {
    return { status: "error" };
  }
  const envelope = raw as { ok?: unknown; value?: unknown; error?: unknown };
  if (envelope.ok === true && typeof envelope.value === "object" && envelope.value !== null) {
    const value = envelope.value as Record<string, unknown>;
    if (value.status === "saved" && typeof value.sha256 === "string") {
      return { status: "saved", sha256: value.sha256 };
    }
    if (value.status === "conflict") {
      return {
        status: "conflict",
        fileMissing: value.fileMissing === true,
        diskSha256: typeof value.diskSha256 === "string" ? value.diskSha256 : undefined,
        diskContent: typeof value.diskContent === "string" ? value.diskContent : undefined,
      };
    }
    return { status: "error" };
  }
  if (typeof envelope.error === "object" && envelope.error !== null) {
    const error = envelope.error as Record<string, unknown>;
    return {
      status: "error",
      code: typeof error.code === "string" ? error.code : undefined,
      detail: typeof error.detail === "string" ? error.detail : undefined,
    };
  }
  return { status: "error" };
}

export class EditorSaveController {
  private readonly bridge: EditorSaveBridge | null;
  /// Invoked once if the native side reports the write capability is gone
  /// (e.g. a session-restored page whose registration died with the previous
  /// app instance); the owner should lock the buffer read-only.
  onSaveUnavailable: (() => void) | null = null;
  private unavailable = false;
  private document: EditorSaveDocument | null = null;
  private baselineSha256: string | null;
  /// True when the page was seeded with content that already diverged from
  /// disk (a host regenerating the editor from an unsaved buffer, e.g. on a
  /// theme change or web-process recovery). The buffer counts as dirty until
  /// a successful save or a disk adoption, even though Monaco's version ids
  /// start out "clean" — otherwise a reload would silently drop the unsaved
  /// state from dirty tracking.
  private initiallyDirty: boolean;
  private savedVersionId: number | null = null;
  private currentVersionId: number | null = null;
  private saving = false;
  private queuedForce: boolean | null = null;
  private status: EditorSaveState["status"] = "idle";
  private errorCode: string | undefined;
  private errorDetail: string | undefined;
  private conflict: EditorSaveConflict | null = null;
  private state: EditorSaveState = { dirty: false, status: "idle", conflict: null };
  private readonly listeners = new Set<() => void>();

  constructor(options: {
    bridge: EditorSaveBridge | null;
    baselineSha256: string | null;
    initiallyDirty?: boolean;
  }) {
    this.bridge = options.bridge;
    this.baselineSha256 = options.baselineSha256;
    this.initiallyDirty = options.initiallyDirty === true;
  }

  attachDocument(document: EditorSaveDocument): void {
    this.document = document;
    this.savedVersionId = document.getVersionId();
    this.currentVersionId = this.savedVersionId;
    this.refreshState();
  }

  detachDocument(): void {
    this.document = null;
  }

  /** Call on every Monaco content change so dirty state stays derived. */
  noteContentChanged(): void {
    if (!this.document) {
      return;
    }
    this.currentVersionId = this.document.getVersionId();
    this.refreshState();
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  getState = (): EditorSaveState => this.state;

  requestSave(options: { force?: boolean } = {}): void {
    const force = options.force ?? false;
    if (!this.document) {
      return;
    }
    if (!this.bridge) {
      this.status = "error";
      this.errorCode = "unavailable";
      this.errorDetail = undefined;
      this.conflict = null;
      this.refreshState();
      return;
    }
    if (!force && !this.isDirty() && this.conflict === null && this.status !== "error") {
      return;
    }
    if (this.saving) {
      this.queuedForce = (this.queuedForce ?? false) || force;
      return;
    }
    void this.performSave(force);
  }

  resolveConflictOverwrite(): void {
    if (this.conflict === null) {
      return;
    }
    this.requestSave({ force: true });
  }

  resolveConflictUseDisk(): void {
    const conflict = this.conflict;
    if (conflict === null || conflict.diskContent === undefined) {
      return;
    }
    this.adoptDiskContent(conflict.diskContent, conflict.diskSha256 ?? null);
  }

  /**
   * Adopts `content` (the bytes currently on disk) as the buffer's synced
   * state: re-baselines dirty tracking plus the conflict sha, replacing the
   * buffer only when the text actually differs (so a disk rewrite with
   * identical text — e.g. an encoding change, or this host's own save echo —
   * never resets the undo stack). A fully identical adoption is a no-op so a
   * save echo also keeps the "Saved" status visible. Used by the conflict
   * card's "Use disk version" resolution, and by native hosts (the markdown
   * panel) on clean-buffer file-watcher changes and explicit reverts.
   */
  adoptDiskContent(content: string, sha256: string | null): void {
    if (!this.document) {
      return;
    }
    const sameContent = this.document.getValue() === content;
    if (sameContent && this.baselineSha256 === sha256 && this.conflict === null) {
      // No-op: e.g. the host's boot-time sync of a page seeded from an
      // unsaved buffer. Deliberately keeps `initiallyDirty` set — the buffer
      // still diverges from disk.
      return;
    }
    const versionId = sameContent ? this.document.getVersionId() : this.document.replaceWith(content);
    this.initiallyDirty = false;
    this.savedVersionId = versionId;
    this.currentVersionId = versionId;
    this.baselineSha256 = sha256;
    this.status = "idle";
    this.errorCode = undefined;
    this.errorDetail = undefined;
    this.conflict = null;
    this.refreshState();
  }

  dismissConflict(): void {
    if (this.conflict === null) {
      return;
    }
    this.conflict = null;
    this.status = "idle";
    this.refreshState();
  }

  private isDirty(): boolean {
    return this.initiallyDirty || this.currentVersionId !== this.savedVersionId;
  }

  private async performSave(force: boolean): Promise<void> {
    const document = this.document;
    const bridge = this.bridge;
    if (!document || !bridge) {
      return;
    }
    const versionId = document.getVersionId();
    const content = document.getValue();
    this.saving = true;
    this.status = "saving";
    this.errorCode = undefined;
    this.errorDetail = undefined;
    this.conflict = null;
    this.refreshState();

    let reply: EditorSaveBridgeReply;
    try {
      reply = await bridge({ content, expectedSha256: this.baselineSha256, force });
    } catch (error) {
      reply = { status: "error", detail: String(error) };
    }
    this.saving = false;

    if (reply.status === "saved") {
      this.initiallyDirty = false;
      this.savedVersionId = versionId;
      this.baselineSha256 = reply.sha256;
      this.status = "saved";
    } else if (reply.status === "conflict") {
      this.queuedForce = null;
      this.status = "idle";
      this.conflict = {
        fileMissing: reply.fileMissing === true,
        diskSha256: reply.diskSha256,
        diskContent: reply.diskContent,
      };
      this.refreshState();
      return;
    } else {
      this.queuedForce = null;
      this.status = "error";
      this.errorCode = reply.code;
      this.errorDetail = reply.detail;
      if (reply.code === "unauthorized" && !this.unavailable) {
        // The native registration for this page is gone (restored page from a
        // previous app run). Surface it as save-unavailable and lock the
        // buffer so edits are not silently discarded.
        this.unavailable = true;
        this.errorCode = "unavailable";
        this.onSaveUnavailable?.();
      }
      this.refreshState();
      return;
    }
    this.refreshState();

    const queuedForce = this.queuedForce;
    this.queuedForce = null;
    if (queuedForce !== null && (this.isDirty() || queuedForce)) {
      void this.performSave(queuedForce);
    }
  }

  private refreshState(): void {
    const next: EditorSaveState = {
      dirty: this.isDirty(),
      status: this.status,
      errorCode: this.errorCode,
      errorDetail: this.errorDetail,
      conflict: this.conflict,
    };
    const previous = this.state;
    if (
      previous.dirty === next.dirty &&
      previous.status === next.status &&
      previous.errorCode === next.errorCode &&
      previous.errorDetail === next.errorDetail &&
      previous.conflict === next.conflict
    ) {
      return;
    }
    this.state = next;
    // Copy before iterating: a listener may unsubscribe during notification.
    for (const listener of Array.from(this.listeners)) {
      listener();
    }
  }
}
