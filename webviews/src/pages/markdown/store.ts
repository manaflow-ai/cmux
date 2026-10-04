// The markdown page's document state: load, autosave through the host, disk changes and conflicts.
// The file is written only when the user edited it: saves come from user edits (debounced), the
// `save` page command (Cmd-S) and page hide, and a save whose text equals the last saved text is
// skipped. A disk change reloads the page when there are no local edits and raises the conflict
// banner when there are.
import { isPageError, type PageClient } from "../shared/pageClient";
import type { SourceMap } from "./sourceMap";
import type { DiffViewerAppearance } from "../../appearance";
import { markdownBehavior } from "./settings";
import {
  MARKDOWN_CHANGES,
  MARKDOWN_LOOK,
  MARKDOWN_CONFIG_OP,
  MARKDOWN_CONFLICT,
  MARKDOWN_SAVE_OP,
  isMarkdownConfig,
  type MarkdownChange,
  type MarkdownConfig,
  type MarkdownConflict,
  type MarkdownLook,
  type MarkdownSaveResult,
} from "./host";

export type MarkdownMode = "rich" | "source";
export type SaveStatus = "saved" | "edited" | "saving" | "failed";

export interface MarkdownState {
  phase: "loading" | "ready" | "failed" | "disconnected";
  config: MarkdownConfig | null;
  mode: MarkdownMode;
  status: SaveStatus;
  readOnly: boolean;
  conflict: MarkdownConflict | null;
  /** The source mode's text. */
  source: string;
  /** Bumped when the document is replaced from outside (load, reload), so source views re-read. */
  revision: number;
  /** The page's look: `markdown` settings, theme.css and the terminal appearance. */
  look: { settings: unknown; themeCSS: string | undefined; appearance: DiffViewerAppearance | undefined };
}

/** The editor surface the store drives (MarkdownEditor, or a fake in tests). */
export interface DocumentEditor {
  load(text: string): void;
  snapshot(): SourceMap;
  commit(map: SourceMap): void;
  setReadOnly(readOnly: boolean): void;
}

export type Schedule = (run: () => void, delayMs: number) => () => void;

const defaultSchedule: Schedule = (run, delayMs) => {
  const timer = setTimeout(run, delayMs);
  return () => clearTimeout(timer);
};

export const AUTOSAVE_DELAY_MS = 800;

export class MarkdownStore {
  private state: MarkdownState = {
    phase: "loading",
    config: null,
    mode: "rich",
    status: "saved",
    readOnly: false,
    conflict: null,
    source: "",
    revision: 0,
    look: { settings: undefined, themeCSS: undefined, appearance: undefined },
  };
  private readonly listeners = new Set<() => void>();
  private editor: DocumentEditor | null = null;
  /** The text on disk as of the last load or save, and its hash. */
  private savedText = "";
  private baseHash: string | null = null;
  private cancelAutosave: (() => void) | null = null;
  private saving: Promise<void> | null = null;
  private saveAgain = false;
  private pendingChange: MarkdownChange | null = null;
  private stopChanges: (() => void) | null = null;
  private stopLook: (() => void) | null = null;
  private started = false;

  constructor(
    private readonly client: PageClient | null,
    private readonly schedule: Schedule = defaultSchedule,
  ) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getState = (): MarkdownState => this.state;

  private set(patch: Partial<MarkdownState>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }

  /** Loads the config and starts watching the file. */
  async start(): Promise<void> {
    const client = this.client;
    if (!client) return this.set({ phase: "disconnected" });
    this.set({ phase: "loading" });
    let config: MarkdownConfig;
    try {
      const value = await client.call<unknown>(MARKDOWN_CONFIG_OP, {});
      if (!isMarkdownConfig(value)) throw new Error("markdown config is malformed");
      config = value;
    } catch (error) {
      console.error("cmux markdown config failed", error);
      return this.set({
        phase: isPageError(error) && error.code === "cmux.protocol.closed" ? "disconnected" : "failed",
      });
    }
    this.savedText = config.text;
    this.baseHash = config.hash;
    const readOnly = config.readOnly === true;
    const look = { settings: config.settings, themeCSS: config.themeCSS, appearance: config.appearance };
    // The settings' default mode applies when the page opens, not on a later settings change.
    const mode = this.started ? this.state.mode : markdownBehavior(config.settings).defaultMode;
    this.started = true;
    this.set({
      phase: "ready",
      config,
      readOnly,
      source: config.text,
      status: "saved",
      revision: this.state.revision + 1,
      look,
      mode,
    });
    this.editor?.setReadOnly(readOnly);
    this.editor?.load(config.text);
    if (!this.stopLook) {
      try {
        this.stopLook = await client.subscribe<MarkdownLook>(MARKDOWN_LOOK, (look) => this.lookChanged(look));
      } catch (error) {
        if (!(isPageError(error) && error.code === "cmux.protocol.unknown_op"))
          console.warn("cmux markdown look", error);
      }
    }
    if (!this.stopChanges) {
      try {
        this.stopChanges = await client.subscribe<MarkdownChange>(MARKDOWN_CHANGES, (change) =>
          this.diskChanged(change),
        );
      } catch (error) {
        if (!(isPageError(error) && error.code === "cmux.protocol.unknown_op"))
          console.warn("cmux markdown changes", error);
      }
    }
  }

  /** The host re-sent part of the look; the rest stays. Applied in place, never by reloading. */
  lookChanged(look: MarkdownLook): void {
    const current = this.state.look;
    this.set({
      look: {
        settings: "settings" in look ? look.settings : current.settings,
        themeCSS: "themeCSS" in look ? look.themeCSS : current.themeCSS,
        appearance: look.appearance ?? current.appearance,
      },
    });
  }

  /** The editor mounted (or unmounted, with null). A loaded file goes into it. */
  attachEditor(editor: DocumentEditor | null): void {
    this.editor = editor;
    if (!editor || this.state.phase !== "ready") return;
    editor.setReadOnly(this.state.readOnly);
    editor.load(this.state.mode === "source" ? this.state.source : this.savedText);
  }

  /** The document as the current mode holds it. */
  currentText(): string {
    if (this.state.mode === "source" || !this.editor) return this.state.source;
    return this.editor.snapshot().text;
  }

  /** A user edit in either mode: the file is edited, and saves after the user pauses. */
  edited(): void {
    if (this.state.readOnly || this.state.phase !== "ready") return;
    if (this.state.status !== "saving") this.set({ status: "edited" });
    this.cancelAutosave?.();
    if (this.state.conflict) return;
    this.cancelAutosave = this.schedule(() => {
      this.cancelAutosave = null;
      void this.save();
    }, AUTOSAVE_DELAY_MS);
  }

  setSource(text: string): void {
    this.set({ source: text });
    this.edited();
  }

  setMode(mode: MarkdownMode): void {
    if (mode === this.state.mode) return;
    if (mode === "source") {
      this.set({
        mode,
        source: this.editor ? this.editor.snapshot().text : this.state.source,
        revision: this.state.revision + 1,
      });
      return;
    }
    // Back to rich text: the editor reloads only when the source changed, so its undo history and
    // save baseline survive a look at the source.
    const source = this.state.source;
    const editorText = this.editor?.snapshot().text;
    this.set({ mode });
    if (this.editor && editorText !== source) this.editor.load(source);
  }

  /** Saves now (Cmd-S, page hide). A save already running saves again when it ends. */
  async save(): Promise<void> {
    this.cancelAutosave?.();
    this.cancelAutosave = null;
    const config = this.state.config;
    if (!config || !this.client || this.state.readOnly || this.state.conflict) return;
    if (this.saving) {
      this.saveAgain = true;
      return this.saving;
    }
    const snapshot = this.state.mode === "rich" && this.editor ? this.editor.snapshot() : null;
    const text = snapshot ? snapshot.text : this.state.source;
    if (text === this.savedText) {
      if (snapshot) this.editor?.commit(snapshot);
      if (this.state.status !== "saved") this.set({ status: "saved" });
      return;
    }
    this.set({ status: "saving" });
    this.saving = (async () => {
      try {
        const result = await this.client!.call<MarkdownSaveResult>(MARKDOWN_SAVE_OP, {
          path: config.path,
          text,
          baseHash: this.baseHash,
        });
        this.savedText = text;
        this.baseHash = result.hash;
        if (snapshot) this.editor?.commit(snapshot);
        this.set({ status: this.currentText() === this.savedText ? "saved" : "edited" });
      } catch (error) {
        if (isPageError(error) && error.code === MARKDOWN_CONFLICT) {
          const details = (error.details ?? {}) as MarkdownConflict;
          this.set({
            status: "edited",
            conflict: { hash: details.hash ?? null, text: details.text, deleted: details.deleted },
          });
        } else {
          console.error("cmux markdown save failed", error);
          this.set({ status: "failed" });
        }
      }
    })();
    try {
      await this.saving;
    } finally {
      this.saving = null;
    }
    const change = this.pendingChange;
    this.pendingChange = null;
    if (change) this.diskChanged(change);
    if (this.saveAgain) {
      this.saveAgain = false;
      if (!this.state.conflict && this.state.status !== "saved") await this.save();
    } else if (this.state.status === "edited" && !this.state.conflict) {
      this.edited();
    }
  }

  /** The file changed on disk. */
  diskChanged(change: MarkdownChange): void {
    if (this.state.phase !== "ready") return;
    if (this.saving) {
      this.pendingChange = change;
      return;
    }
    if (!change.deleted && change.hash === this.baseHash) return;
    const edited = this.currentText() !== this.savedText;
    if (!edited && !change.deleted && typeof change.text === "string") {
      this.replace(change.text, change.hash);
      return;
    }
    this.cancelAutosave?.();
    this.cancelAutosave = null;
    this.set({ conflict: { hash: change.hash, text: change.text, deleted: change.deleted } });
  }

  /** Conflict banner: drop local edits and load the file from disk. */
  reloadFromDisk(): void {
    const conflict = this.state.conflict;
    if (!conflict || conflict.deleted || typeof conflict.text !== "string") return;
    this.set({ conflict: null });
    this.replace(conflict.text, conflict.hash);
  }

  /** Conflict banner: keep the local edits and write them over the file on disk. */
  async keepMine(): Promise<void> {
    const conflict = this.state.conflict;
    if (!conflict) return;
    this.baseHash = conflict.deleted ? null : conflict.hash;
    this.savedText = conflict.deleted ? "" : (conflict.text ?? "");
    this.set({ conflict: null, status: "edited" });
    await this.save();
  }

  private replace(text: string, hash: string | null): void {
    this.savedText = text;
    this.baseHash = hash;
    this.set({ source: text, status: "saved", revision: this.state.revision + 1 });
    this.editor?.load(text);
  }

  dispose(): void {
    this.cancelAutosave?.();
    this.stopChanges?.();
    this.stopChanges = null;
    this.stopLook?.();
    this.stopLook = null;
  }
}
