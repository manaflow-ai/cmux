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
  private document: EditorSaveDocument | null = null;
  private baselineSha256: string | null;
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

  constructor(options: { bridge: EditorSaveBridge | null; baselineSha256: string | null }) {
    this.bridge = options.bridge;
    this.baselineSha256 = options.baselineSha256;
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
    if (!this.document || conflict === null || conflict.diskContent === undefined) {
      return;
    }
    const versionId = this.document.replaceWith(conflict.diskContent);
    this.savedVersionId = versionId;
    this.currentVersionId = versionId;
    this.baselineSha256 = conflict.diskSha256 ?? null;
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
    return this.currentVersionId !== this.savedVersionId;
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
