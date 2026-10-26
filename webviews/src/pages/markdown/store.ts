// The markdown page's document state: load, autosave through the host, disk changes and conflicts.
// The file is written only when the user edited it: saves come from user edits (debounced), the
// `save` page command (Cmd-S) and page hide, and a save whose text equals the last saved text is
// skipped. A disk change reloads the page when there are no local edits and raises the conflict
// banner when there are.
import { isPageError, type PageClient } from "../shared/pageClient";
import type { SourceMap } from "./sourceMap";
import type { DiffViewerAppearance } from "../../appearance";
import { markdownBehavior } from "./settings";
import { createEditReporter } from "../shared/editReporter";
import { MARKDOWN_OPEN_OP, markdownConfigNeedsPick } from "../../viewer-empty/ops";
import {
  MARKDOWN_CHANGES,
  MARKDOWN_UNAVAILABLE,
  MARKDOWN_LOOK,
  MARKDOWN_CONFIG_OP,
  MARKDOWN_CONFLICT,
  MARKDOWN_EDITED_OP,
  MARKDOWN_HISTORY_OP,
  MARKDOWN_LOAD_REMOTE_IMAGES_OP,
  MARKDOWN_SAVE_OP,
  MARKDOWN_SET_PREFERENCE_OP,
  isMarkdownConfig,
  type MarkdownChange,
  type MarkdownConfig,
  type MarkdownFile,
  type MarkdownConflict,
  type MarkdownLook,
  type MarkdownReadOnlyReason,
  type MarkdownSaveResult,
} from "./host";

export type MarkdownMode = "rich" | "source";
export type SaveStatus = "saved" | "edited" | "saving" | "failed";

export interface MarkdownState {
  /** `empty`: the host has no file for the page yet; the empty state picks one (openFile). */
  phase: "loading" | "ready" | "failed" | "disconnected" | "empty";
  config: MarkdownConfig | null;
  mode: MarkdownMode;
  status: SaveStatus;
  readOnly: boolean;
  /** Why the file is read only (null while it is not). */
  readOnlyReason: MarkdownReadOnlyReason | null;
  conflict: MarkdownConflict | null;
  /** The source mode's text. */
  source: string;
  /** Bumped when the document is replaced from outside (load, reload), so source views re-read. */
  revision: number;
  /** The page's look: `markdown` settings, theme.css and the terminal appearance. */
  look: { settings: unknown; themeCSS: string | undefined; appearance: DiffViewerAppearance | undefined };
  /** Link history (files followed in this page): whether `back` and `forward` go anywhere. */
  canBack: boolean;
  canForward: boolean;
  /**
   * The file a followed link (or back/forward) is opening, named in the toolbar in the input's
   * frame while it loads (plans/cmux-next/zero-latency.md, rule a); null otherwise.
   */
  navigating: string | null;
  /** The last navigation that did not open its file (shown until the next one), or null. */
  navigationFailed: string | null;
  /** Why the file did not open, as the host says it (its machine is offline); null: the generic message. */
  failure: string | null;
  /** The file's machine stopped answering (the host's reason); the page keeps what it last read. */
  unavailable: string | null;
}

/** One file in the page's link history, with the anchor it opened at and its scroll offset. */
export interface HistoryEntry {
  path: string;
  anchor: string;
  scroll: number;
}

/** The editor surface the store drives (MarkdownEditor, or a fake in tests). */
export interface DocumentEditor {
  load(text: string): void;
  snapshot(): SourceMap;
  commit(map: SourceMap): void;
  setReadOnly(readOnly: boolean): void;
}

export type Schedule = (run: () => void, delayMs: number) => () => void;

/** How long a Reading Settings value waits for the next change before it is written (a slider drag). */
export const PREFERENCE_WRITE_DELAY_MS = 250;

/**
 * `section` (the `markdown` settings object) with `path` (dotted, below `markdown.`) set to
 * `value`; null removes the key, so the option goes back to its default. Never mutates `section`.
 */
export function withMarkdownSetting(section: unknown, path: string, value: unknown): Record<string, unknown> {
  const plain = (entry: unknown): Record<string, unknown> =>
    entry && typeof entry === "object" && !Array.isArray(entry) ? { ...(entry as Record<string, unknown>) } : {};
  const root = plain(section);
  const parts = path.split(".");
  let node = root;
  for (const part of parts.slice(0, -1)) {
    node[part] = plain(node[part]);
    node = node[part] as Record<string, unknown>;
  }
  const last = parts.at(-1)!;
  if (value === null) delete node[last];
  else node[last] = value;
  return root;
}

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
    readOnlyReason: null,
    conflict: null,
    source: "",
    revision: 0,
    look: { settings: undefined, themeCSS: undefined, appearance: undefined },
    canBack: false,
    canForward: false,
    navigating: null,
    navigationFailed: null,
    failure: null,
    unavailable: null,
  };
  private history: { entries: HistoryEntry[]; index: number } = { entries: [], index: -1 };
  /** The history state the host last heard (`cmux.markdown.history`), as `canBack:canForward`. */
  private toldHost: string | null = null;
  private readonly listeners = new Set<() => void>();
  private editor: DocumentEditor | null = null;
  /** The text on disk as of the last load or save, and its hash. */
  private savedText = "";
  private baseHash: string | null = null;
  /**
   * A recovered crash draft (R96) the page loaded as unsaved edits, until a save, a reload or
   * another file replaces it: an editor that mounts after the load shows it, not the file.
   */
  private recovered: string | null = null;
  private cancelAutosave: (() => void) | null = null;
  private saving: Promise<void> | null = null;
  private saveAgain = false;
  private pendingChange: MarkdownChange | null = null;
  private stopChanges: (() => void) | null = null;
  private stopLook: (() => void) | null = null;
  /** Reading Settings values not yet written, by `markdown.*` key, and their pending writes. */
  private readonly unsentPreferences = new Map<string, { value: unknown; cancel: () => void }>();
  private started = false;
  private readonly reporter;

  constructor(
    private readonly client: PageClient | null,
    private readonly schedule: Schedule = defaultSchedule,
    reportSchedule: Schedule = defaultSchedule,
  ) {
    this.reporter = createEditReporter(() => this.reportEdited(), reportSchedule);
  }

  /** `cmux.markdown.edited`: the host's unsaved state and recovery draft follow the document. */
  private reportEdited(): void {
    const config = this.state.config;
    if (!config || !this.client || this.state.readOnly) return;
    this.client
      .call<unknown>(MARKDOWN_EDITED_OP, { path: config.path, text: this.currentText(), baseHash: this.baseHash })
      .catch((error) => {
        if (!(isPageError(error) && error.code === "cmux.protocol.unknown_op"))
          console.warn("cmux markdown edited", error);
      });
  }

  /** The host's `cmux.markdown.flush`: saves pending edits now; `dirty` when some are still not on disk. */
  async flush(): Promise<{ dirty: boolean }> {
    if (this.state.readOnly) return { dirty: false };
    if (!this.state.conflict && this.currentText() !== this.savedText) await this.save();
    return { dirty: this.state.conflict !== null || this.currentText() !== this.savedText };
  }

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
      if (markdownConfigNeedsPick(value)) {
        // The empty state still follows the look (terminal appearance) the host sends with it.
        const look = value as Partial<MarkdownLook>;
        return this.set({
          phase: "empty",
          look: { settings: look.settings, themeCSS: look.themeCSS, appearance: look.appearance },
        });
      }
      if (!isMarkdownConfig(value)) throw new Error("markdown config is malformed");
      config = value;
    } catch (error) {
      console.error("cmux markdown config failed", error);
      return this.set({
        phase: isPageError(error) && error.code === "cmux.protocol.closed" ? "disconnected" : "failed",
        failure: isPageError(error) && error.code === MARKDOWN_UNAVAILABLE ? error.message : null,
      });
    }
    await this.loadConfig(client, config);
  }

  /**
   * Opens `path` from the empty state: `cmux.markdown.open` answers its config, which loads as
   * the page's file. Rejects with the host's error (the empty state shows it).
   */
  async openFile(path: string): Promise<void> {
    const client = this.client;
    if (!client) throw new Error("markdown page has no host");
    const value = await client.call<unknown>(MARKDOWN_OPEN_OP, { path });
    if (!isMarkdownConfig(value)) throw new Error("markdown config is malformed");
    await this.loadConfig(client, value);
  }

  private async loadConfig(client: PageClient, config: MarkdownConfig): Promise<void> {
    this.savedText = config.text;
    this.baseHash = config.hash;
    const readOnly = config.readOnly === true;
    // A recovered draft opens as unsaved edits on the file's current hash (the editor page's rule).
    this.recovered =
      !readOnly && typeof config.recoveredText === "string" && config.recoveredText !== config.text
        ? config.recoveredText
        : null;
    const text = this.recovered ?? config.text;
    const look = { settings: config.settings, themeCSS: config.themeCSS, appearance: config.appearance };
    // The settings' default mode applies when the page opens, not on a later settings change.
    const mode = this.started ? this.state.mode : markdownBehavior(config.settings).defaultMode;
    this.started = true;
    this.set({
      phase: "ready",
      config,
      readOnly,
      readOnlyReason: readOnly ? (config.readOnlyReason ?? "outside") : null,
      source: text,
      status: "saved",
      revision: this.state.revision + 1,
      failure: null,
      unavailable: null,
      look,
      mode,
    });
    this.history = { entries: [{ path: config.path, anchor: "", scroll: 0 }], index: 0 };
    this.historyMoved();
    this.editor?.setReadOnly(readOnly);
    this.editor?.load(text);
    if (this.recovered !== null) this.edited();
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
    let settings = "settings" in look ? look.settings : current.settings;
    // A value the person just chose and the page has not written yet stays on screen.
    for (const [key, { value }] of this.unsentPreferences)
      settings = withMarkdownSetting(settings, key.replace(/^markdown\./, ""), value);
    this.set({
      look: {
        settings,
        themeCSS: "themeCSS" in look ? look.themeCSS : current.themeCSS,
        appearance: look.appearance ?? current.appearance,
      },
    });
  }

  /**
   * A Reading Settings change: `key` is a `markdown.*` settings key, `value` null resets it. The
   * page shows it at once; the write to the settings file (`cmux.markdown.setPreference`, the one
   * settings write path) waits `PREFERENCE_WRITE_DELAY_MS` for the next change of the same key, so
   * a slider drag writes once. The host's look event confirms it.
   */
  setPreference(key: string, value: unknown): void {
    if (!key.startsWith("markdown.")) return;
    this.set({
      look: { ...this.state.look, settings: withMarkdownSetting(this.state.look.settings, key.slice(9), value) },
    });
    this.unsentPreferences.get(key)?.cancel();
    const cancel = this.schedule(() => {
      this.unsentPreferences.delete(key);
      void this.client?.call(MARKDOWN_SET_PREFERENCE_OP, { key, value }).catch((error: unknown) => {
        console.warn("cmux markdown setPreference failed", error);
      });
    }, PREFERENCE_WRITE_DELAY_MS);
    this.unsentPreferences.set(key, { value, cancel });
  }

  /** Writes every Reading Settings value still waiting (the popover closed, the page hides). */
  flushPreferences(): void {
    for (const [key, { value, cancel }] of this.unsentPreferences) {
      cancel();
      this.unsentPreferences.delete(key);
      void this.client?.call(MARKDOWN_SET_PREFERENCE_OP, { key, value }).catch((error: unknown) => {
        console.warn("cmux markdown setPreference failed", error);
      });
    }
  }

  /** A real click asked the host to approve guarded web images for this document. */
  async loadRemoteImages(): Promise<void> {
    const client = this.client;
    const config = this.state.config;
    if (!client || !config || config.remoteImageBase) return;
    const path = config.path;
    const answer = await client.call<{ remoteImageBase?: unknown }>(MARKDOWN_LOAD_REMOTE_IMAGES_OP, { path });
    if (typeof answer?.remoteImageBase !== "string" || !answer.remoteImageBase) {
      throw new Error("markdown remote-image approval is malformed");
    }
    const current = this.state.config;
    if (current?.path === path) this.set({ config: { ...current, remoteImageBase: answer.remoteImageBase } });
  }

  /** The editor mounted (or unmounted, with null). A loaded file goes into it. */
  attachEditor(editor: DocumentEditor | null): void {
    this.editor = editor;
    if (!editor || this.state.phase !== "ready") return;
    editor.setReadOnly(this.state.readOnly);
    editor.load(this.state.mode === "source" ? this.state.source : (this.recovered ?? this.savedText));
  }

  /** The document as the current mode holds it. */
  currentText(): string {
    if (this.state.mode === "source" || !this.editor) return this.state.source;
    return this.editor.snapshot().text;
  }

  /** A user edit in either mode: the file is edited, and saves after the user pauses. */
  edited(): void {
    if (this.state.readOnly || this.state.phase !== "ready") return;
    this.reporter.edited();
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
        this.recovered = null;
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

  /**
   * Follows a link to another markdown file (or an anchor in this one): saves pending edits, loads
   * the file in place and pushes it on the link history. Resolves to the entry shown, or null when
   * the page stays (unsaved edits that would not save, a conflict, a load failure).
   */
  async navigate(path: string, anchor: string, scroll: number): Promise<HistoryEntry | null> {
    if (!(await this.show(path))) return null;
    const { entries, index } = this.history;
    const current = entries[index];
    const entry = { path: this.state.config!.path, anchor, scroll: 0 };
    // The place the page already is (the same anchor again) adds no entry.
    if (current && current.path === entry.path && current.anchor === anchor) return current;
    if (current) current.scroll = scroll;
    entries.splice(index + 1, entries.length, entry);
    this.history.index = entries.length - 1;
    this.historyMoved();
    return entry;
  }

  /**
   * Reload (Cmd-R, the omnibar's Reload): pending edits are saved, then the file is read from
   * disk again and shown in place; the history stays. False when the page cannot (no file, a
   * conflict, edits that would not save, a read failure).
   */
  async reload(): Promise<boolean> {
    const path = this.state.config?.path;
    if (this.state.phase !== "ready" || !path) return false;
    return this.show(path, true);
  }

  /** The history index moved: `canBack` and `canForward` follow, and the host hears of a change. */
  private historyMoved(): void {
    const { entries, index } = this.history;
    const canBack = index > 0;
    const canForward = index < entries.length - 1;
    this.set({ canBack, canForward });
    const told = `${canBack}:${canForward}`;
    if (told === this.toldHost || !this.client) return;
    this.toldHost = told;
    void this.client.call(MARKDOWN_HISTORY_OP, { canBack, canForward }).catch(() => undefined);
  }

  /** A link to another markdown file was followed: name it now, before anything loads. */
  beginNavigation(target: string): void {
    this.set({ navigating: target, navigationFailed: null });
  }

  /**
   * The navigation ended. Shown files clear `navigating` themselves; one still set here did not
   * open, and is named as failed unless `failed` is false (the link went to another viewer).
   */
  endNavigation(failed = true): void {
    const target = this.state.navigating;
    if (target !== null) this.set({ navigating: null, navigationFailed: failed ? target : null });
  }

  /** `back` (-1) and `forward` (+1) page commands: the link history entry, shown in place. */
  async go(delta: -1 | 1, scroll: number): Promise<HistoryEntry | null> {
    const { entries, index } = this.history;
    const target = entries[index + delta];
    if (!target) return null;
    if (target.path !== this.state.config?.path) this.beginNavigation(target.path);
    if (!(await this.show(target.path))) {
      this.endNavigation();
      return null;
    }
    if (entries[index]) entries[index].scroll = scroll;
    this.history.index = index + delta;
    this.historyMoved();
    return target;
  }

  /**
   * Shows `path` in the page; true when it is shown (already, or loaded now). `reread` reads the
   * file shown now from disk again (Reload).
   */
  private async show(path: string, reread = false): Promise<boolean> {
    const config = this.state.config;
    if (!config || !this.client) return false;
    if (path === config.path && !reread) {
      if (this.state.navigating !== null) this.set({ navigating: null });
      return true;
    }
    // Edits are saved before the page leaves the file; a file that would lose them stays.
    if (!this.state.readOnly && this.currentText() !== this.savedText) await this.save();
    if (this.state.conflict || (!this.state.readOnly && this.currentText() !== this.savedText)) return false;
    let file: MarkdownFile;
    try {
      const value = await this.client.call<unknown>(MARKDOWN_OPEN_OP, { path });
      if (!isMarkdownConfig(value)) throw new Error("markdown file is malformed");
      file = value;
    } catch (error) {
      console.error("cmux markdown load failed", error);
      return false;
    }
    this.cancelAutosave?.();
    this.cancelAutosave = null;
    this.savedText = file.text;
    this.baseHash = file.hash;
    this.recovered = null;
    const readOnly = file.readOnly === true;
    this.set({
      config: {
        ...config,
        path: file.path,
        text: file.text,
        hash: file.hash,
        githubRepository: file.githubRepository,
        readOnly,
        readOnlyReason: file.readOnlyReason,
        assetBase: file.assetBase,
      },
      readOnly,
      readOnlyReason: readOnly ? (file.readOnlyReason ?? "outside") : null,
      source: file.text,
      status: "saved",
      conflict: null,
      revision: this.state.revision + 1,
      navigating: null,
    });
    this.editor?.setReadOnly(readOnly);
    this.editor?.load(file.text);
    return true;
  }

  /** The file changed on disk. */
  diskChanged(change: MarkdownChange): void {
    if (this.state.phase !== "ready") return;
    // Changes of a file the page left (its watcher may still report) are not this file's.
    if (change.path && this.state.config && change.path !== this.state.config.path) return;
    // The file's machine went away or came back: a notice, never a change of the text.
    if (change.unavailable !== undefined) return this.set({ unavailable: change.unavailable });
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
    this.recovered = null;
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
