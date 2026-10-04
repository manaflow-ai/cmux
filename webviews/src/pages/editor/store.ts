// The code editor's document state: load, save through the host, disk changes and conflicts. The
// file is written only when the user edited it: a save happens on the `save` page command (Cmd-S),
// after a pause when `editor.autoSave` is "afterDelay", on page hide and on the host's
// `cmux.editor.flush`, and a save whose text equals the text on disk is skipped. A disk change reloads
// the file when there are no local edits and raises the conflict banner when there are.
import { isPageError, type PageClient } from "../shared/pageClient";
import type { DiffViewerAppearance } from "../../appearance";
import {
  EDITOR_CHANGES,
  EDITOR_CONFIG_OP,
  EDITOR_CONFLICT,
  EDITOR_LOOK,
  EDITOR_OPEN_OP,
  EDITOR_SAVE_OP,
  EDITOR_SET_PREFERENCE_OP,
  editorConfigNeedsPick,
  isEditorConfig,
  type EditorChange,
  type EditorConfig,
  type EditorConflict,
  type EditorLook,
  type EditorSaveResult,
  type ReadOnlyReason,
} from "./host";
import { resolveEditorSettings } from "./settings";

export type SaveStatus = "saved" | "edited" | "saving" | "failed";

export interface EditorLookState {
  settings: unknown;
  syntaxTheme: unknown;
  themeCSS: string | undefined;
  appearance: DiffViewerAppearance | undefined;
  languages: unknown;
  screenReader: boolean;
}

/** The file the page shows, without its text (the view holds the text). */
export interface EditorFileState {
  path: string;
  size: number;
}

export interface EditorState {
  /** `empty`: the host has no file for the page yet; the empty state picks one (openFile). */
  phase: "loading" | "ready" | "failed" | "disconnected" | "empty";
  file: EditorFileState | null;
  status: SaveStatus;
  readOnly: boolean;
  readOnlyReason: ReadOnlyReason | null;
  conflict: EditorConflict | null;
  /** Bumped whenever the document is replaced from outside (load, reload), so the view reloads. */
  revision: number;
  look: EditorLookState;
}

/** A document the view loads: the file's full text (BOM and line endings included). */
export interface EditorDocument {
  path: string;
  text: string;
  size: number;
  readOnly: boolean;
}

/** The editor surface the store drives (the Monaco view, or a fake in tests). */
export interface CodeView {
  load(document: EditorDocument): void;
  /** The file's text as it would be written: BOM and line endings as the file had them. */
  text(): string;
  /** A number that returns to an earlier value when the edits are undone back to it. */
  version(): number;
  setReadOnly(readOnly: boolean): void;
  /** Formats the document (format on save), when a formatter exists for its language. */
  format?(): Promise<void>;
}

export type Schedule = (run: () => void, delayMs: number) => () => void;

const defaultSchedule: Schedule = (run, delayMs) => {
  const timer = setTimeout(run, delayMs);
  return () => clearTimeout(timer);
};

const EMPTY_LOOK: EditorLookState = {
  settings: undefined,
  syntaxTheme: undefined,
  themeCSS: undefined,
  appearance: undefined,
  languages: undefined,
  screenReader: false,
};

function lookOf(value: Partial<EditorConfig> | Partial<EditorLook>): EditorLookState {
  return {
    settings: value.settings,
    syntaxTheme: value.syntaxTheme,
    themeCSS: value.themeCSS,
    appearance: value.appearance,
    languages: value.languages,
    screenReader: value.screenReader === true,
  };
}

/** `section` with `path` (`minimap.enabled`) set to `value`; `section` itself is not changed. */
export function withSetting(section: unknown, path: string, value: unknown): Record<string, unknown> {
  const plain = (entry: unknown): Record<string, unknown> =>
    entry && typeof entry === "object" && !Array.isArray(entry) ? { ...(entry as Record<string, unknown>) } : {};
  const root = plain(section);
  const parts = path.split(".");
  let node = root;
  for (const part of parts.slice(0, -1)) {
    // A boolean shorthand (`minimap: false`) becomes the object form it stands for.
    const current = node[part];
    node[part] = typeof current === "boolean" ? { enabled: current } : plain(current);
    node = node[part] as Record<string, unknown>;
  }
  node[parts.at(-1)!] = value;
  return root;
}

export class EditorStore {
  private state: EditorState = {
    phase: "loading",
    file: null,
    status: "saved",
    readOnly: false,
    readOnlyReason: null,
    conflict: null,
    revision: 0,
    look: EMPTY_LOOK,
  };
  private readonly listeners = new Set<() => void>();
  private view: CodeView | null = null;
  /** The document waiting for the view (load before the view mounted). */
  private pending: EditorDocument | null = null;
  /** The text on disk as of the last load or save, its hash, and the view version that matches it. */
  private savedText = "";
  private baseHash: string | null = null;
  private savedVersion: number | null = null;
  private cancelAutosave: (() => void) | null = null;
  private saving: Promise<void> | null = null;
  private saveAgain = false;
  private pendingChange: EditorChange | null = null;
  private stopChanges: (() => void) | null = null;
  private stopLook: (() => void) | null = null;

  constructor(
    private readonly client: PageClient | null,
    private readonly schedule: Schedule = defaultSchedule,
  ) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getState = (): EditorState => this.state;

  private set(patch: Partial<EditorState>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }

  /** Loads the config and starts watching the file. */
  async start(): Promise<void> {
    const client = this.client;
    if (!client) return this.set({ phase: "disconnected" });
    this.set({ phase: "loading" });
    let value: unknown;
    try {
      value = await client.call<unknown>(EDITOR_CONFIG_OP, {});
    } catch (error) {
      console.error("cmux editor config failed", error);
      return this.set({
        phase: isPageError(error) && error.code === "cmux.protocol.closed" ? "disconnected" : "failed",
      });
    }
    if (editorConfigNeedsPick(value)) {
      // The empty state still follows the look the host sends with it.
      this.set({ phase: "empty", look: lookOf(value as Partial<EditorLook>) });
      await this.subscribeStreams(client);
      return;
    }
    if (!isEditorConfig(value)) {
      console.error("cmux editor config is malformed");
      return this.set({ phase: "failed" });
    }
    await this.loadConfig(client, value);
  }

  /** Opens `path` (the empty state): `cmux.editor.open` answers its config. Rejects with the host's error. */
  async openFile(path: string): Promise<void> {
    const client = this.client;
    if (!client) throw new Error("editor page has no host");
    if (this.state.phase === "ready" && !(await this.leaveFile())) throw new Error("unsaved edits");
    const value = await client.call<unknown>(EDITOR_OPEN_OP, { path });
    if (!isEditorConfig(value)) throw new Error("editor config is malformed");
    await this.loadConfig(client, value);
  }

  /** Saves pending edits before the page shows another file; false when they did not save. */
  private async leaveFile(): Promise<boolean> {
    if (this.state.readOnly || !this.isDirty()) return true;
    await this.save();
    return !this.state.conflict && !this.isDirty();
  }

  private async loadConfig(client: PageClient, config: EditorConfig): Promise<void> {
    this.cancelAutosave?.();
    this.cancelAutosave = null;
    this.savedText = config.text;
    this.baseHash = config.hash;
    const readOnly = config.readOnly === true;
    const size = typeof config.size === "number" ? config.size : config.text.length;
    this.set({
      phase: "ready",
      file: { path: config.path, size },
      readOnly,
      readOnlyReason: readOnly ? (config.readOnlyReason ?? "outside") : null,
      status: "saved",
      conflict: null,
      revision: this.state.revision + 1,
      look: lookOf(config),
    });
    this.show({ path: config.path, text: config.text, size, readOnly });
    await this.subscribeStreams(client);
  }

  private async subscribeStreams(client: PageClient): Promise<void> {
    const tolerate = (error: unknown, name: string) => {
      if (!(isPageError(error) && error.code === "cmux.protocol.unknown_op"))
        console.warn(`cmux editor ${name}`, error);
    };
    if (!this.stopLook) {
      try {
        this.stopLook = await client.subscribe<EditorLook>(EDITOR_LOOK, (look) => this.lookChanged(look));
      } catch (error) {
        tolerate(error, "look");
      }
    }
    if (!this.stopChanges && this.state.phase === "ready") {
      try {
        this.stopChanges = await client.subscribe<EditorChange>(EDITOR_CHANGES, (change) => this.diskChanged(change));
      } catch (error) {
        tolerate(error, "changes");
      }
    }
  }

  /** Hands the document to the view, or keeps it until the view mounts. */
  private show(document: EditorDocument): void {
    if (!this.view) {
      this.pending = document;
      return;
    }
    this.pending = null;
    this.view.load(document);
    this.savedVersion = this.view.version();
  }

  /** The view mounted (or unmounted, with null). A loaded file goes into it. */
  attachView(view: CodeView | null): void {
    this.view = view;
    if (!view) return;
    const pending = this.pending;
    if (pending) this.show(pending);
  }

  /** The host re-sent part of the look; the rest stays. Applied in place, never by reloading. */
  lookChanged(look: EditorLook): void {
    const current = this.state.look;
    this.set({
      look: {
        settings: "settings" in look ? look.settings : current.settings,
        syntaxTheme: "syntaxTheme" in look ? look.syntaxTheme : current.syntaxTheme,
        themeCSS: "themeCSS" in look ? look.themeCSS : current.themeCSS,
        appearance: look.appearance ?? current.appearance,
        languages: "languages" in look ? look.languages : current.languages,
        screenReader: "screenReader" in look ? look.screenReader === true : current.screenReader,
      },
    });
  }

  /**
   * A toolbar toggle: writes one `editor.*` key through the host (the settings store), and applies it
   * at once. The host's look event confirms it; a failed write puts the old value back.
   */
  async setPreference(key: string, value: unknown): Promise<void> {
    const path = key.replace(/^editor\./, "");
    const previous = this.state.look.settings;
    this.set({ look: { ...this.state.look, settings: withSetting(previous, path, value) } });
    if (!this.client) return;
    try {
      await this.client.call(EDITOR_SET_PREFERENCE_OP, { key: `editor.${path}`, value });
    } catch (error) {
      console.warn("cmux editor setPreference failed", error);
      this.set({ look: { ...this.state.look, settings: previous } });
    }
  }

  /** Whether the view holds edits that are not on disk (cheap: no text comparison). */
  isDirty(): boolean {
    if (this.state.phase !== "ready" || !this.view || this.savedVersion === null) return false;
    return this.view.version() !== this.savedVersion;
  }

  /** A user edit (the view's content changed by the user). */
  edited(): void {
    if (this.state.readOnly || this.state.phase !== "ready") return;
    const dirty = this.isDirty();
    if (this.state.status !== "saving") this.set({ status: dirty ? "edited" : "saved" });
    this.cancelAutosave?.();
    this.cancelAutosave = null;
    if (!dirty || this.state.conflict) return;
    const settings = resolveEditorSettings(this.state.look.settings);
    if (settings.autoSave !== "afterDelay") return;
    this.cancelAutosave = this.schedule(() => {
      this.cancelAutosave = null;
      void this.save();
    }, settings.autoSaveDelay);
  }

  /** Saves now (Cmd-S, page hide, flush). A save already running saves again when it ends. */
  async save(options: { format?: boolean } = {}): Promise<void> {
    this.cancelAutosave?.();
    this.cancelAutosave = null;
    const file = this.state.file;
    const view = this.view;
    if (!file || !view || !this.client || this.state.readOnly || this.state.conflict) return;
    if (this.saving) {
      this.saveAgain = true;
      return this.saving;
    }
    if (options.format && view.format && resolveEditorSettings(this.state.look.settings).formatOnSave) {
      await view.format().catch(() => undefined);
    }
    const version = view.version();
    if (version === this.savedVersion) {
      if (this.state.status !== "saved") this.set({ status: "saved" });
      return;
    }
    const text = view.text();
    if (text === this.savedText) {
      // Edited back to what is on disk: nothing to write.
      this.savedVersion = version;
      this.set({ status: "saved" });
      return;
    }
    this.set({ status: "saving" });
    this.saving = (async () => {
      try {
        const result = await this.client!.call<EditorSaveResult>(EDITOR_SAVE_OP, {
          path: file.path,
          text,
          baseHash: this.baseHash,
        });
        this.savedText = text;
        this.baseHash = result.hash;
        this.savedVersion = version;
        this.set({ status: view.version() === version ? "saved" : "edited" });
      } catch (error) {
        if (isPageError(error) && error.code === EDITOR_CONFLICT) {
          const details = (error.details ?? {}) as EditorConflict;
          this.set({
            status: "edited",
            conflict: { hash: details.hash ?? null, text: details.text, deleted: details.deleted },
          });
        } else {
          console.error("cmux editor save failed", error);
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
      if (!this.state.conflict && this.isDirty()) await this.save();
    } else if (this.state.status === "edited" && !this.state.conflict) {
      this.edited();
    }
  }

  /** The host's `cmux.editor.flush`: saves pending edits now; `dirty` when some are still not on disk. */
  async flush(): Promise<{ dirty: boolean }> {
    if (!this.state.readOnly && this.isDirty() && !this.state.conflict) await this.save();
    return { dirty: !this.state.readOnly && this.isDirty() };
  }

  /** The file changed on disk. */
  diskChanged(change: EditorChange): void {
    if (this.state.phase !== "ready") return;
    // Changes of a file the page left (its watcher may still report) are not this file's.
    if (change.path && this.state.file && change.path !== this.state.file.path) return;
    if (this.saving) {
      this.pendingChange = change;
      return;
    }
    if (!change.deleted && change.hash === this.baseHash) return;
    if (!this.isDirty() && !change.deleted && typeof change.text === "string") {
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
    const file = this.state.file;
    if (!file) return;
    this.savedText = text;
    this.baseHash = hash;
    this.set({ status: "saved", revision: this.state.revision + 1, file: { ...file, size: text.length } });
    this.show({ path: file.path, text, size: text.length, readOnly: this.state.readOnly });
  }

  dispose(): void {
    this.cancelAutosave?.();
    this.stopChanges?.();
    this.stopChanges = null;
    this.stopLook?.();
    this.stopLook = null;
  }
}
