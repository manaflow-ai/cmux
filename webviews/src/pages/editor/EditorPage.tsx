// The code editor page (plans/cmux-next/diff-host.md "Editor page"). State lives in `EditorStore`
// (the document) and `StatusStore` (cursor, language, line endings from the view); this file renders
// them: a toolbar (file, save status, word wrap and minimap toggles), the conflict banner, notes, the
// Monaco host element and a status bar. Monaco mounts through a callback ref. Cmd/Ctrl chords (Cmd-S)
// come from the app's key dispatcher as page commands, never from page key handlers.
import { useState, useSyncExternalStore, type ReactNode } from "react";
import { useAutoRetry } from "../../agent-session/acpmux/autoRetry";
import type { Strings } from "../shared/i18n";
import type { ReadOnlyReason } from "./host";
import { PREFERENCE_KEYS, isLargeFile, resolveEditorSettings } from "./settings";
import type { EditorFind } from "./editorFind";
import { EditorFindBar } from "./EditorFindBar";
import type { EditorStore } from "./store";
import { L } from "./strings";
import type { ViewStatus } from "./view";

/** The view's status for the status bar (written by the view, read by React). */
export class StatusStore {
  private status: ViewStatus | null = null;
  private readonly listeners = new Set<() => void>();
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  get = () => this.status;
  set(status: ViewStatus | null): void {
    this.status = status;
    for (const listener of this.listeners) listener();
  }
}

export interface EditorPageProps {
  store: EditorStore;
  status: StatusStore;
  /** Cmd-F's state: the shared find pill over the editor (absent in tests that render no editor). */
  find?: EditorFind;
  strings: Strings;
  /** Mounts the editor into its element (and unmounts it on null). */
  editorRef: (element: HTMLDivElement | null) => void;
  /** Vim's mode line (`editor.vimMode`), which the view's vim writes; the status bar shows it. */
  vimLine?: HTMLElement;
  /** The page with no file (store phase `empty`): the viewer empty state. */
  emptyState?: () => ReactNode;
}

const READ_ONLY_NOTE: Record<ReadOnlyReason, string> = {
  outside: L.readOnlyOutside,
  encoding: L.readOnlyEncoding,
  binary: L.readOnlyBinary,
  permission: L.readOnlyPermission,
};

function fileName(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}

export function EditorPage({ store, status, find, strings, editorRef, vimLine, emptyState }: EditorPageProps) {
  const state = useSyncExternalStore(store.subscribe, store.getState);
  const view = useSyncExternalStore(status.subscribe, status.get);
  const { t } = strings;
  // A lost link or a read that failed is read again on its own (Leo, 2026-11-22: a "try again" is a
  // vacuous decision), and at once when the link is back (`linkChanged`). A launch or a daemon restart
  // drops the link for a few seconds, so the page stays blank, and only a failure that lasts the
  // deadline says so, in one quiet line with no button. A file that cannot open at all (not found, too
  // large) says so at once; reading again in the background still opens it once it can.
  const [asking, setAsking] = useState(false);
  const down = state.phase === "disconnected" || state.phase === "failed";
  const { stillTrying } = useAutoRetry(
    down ? state.phase : false,
    () => {
      setAsking(true);
      void store.start().finally(() => setAsking(false));
    },
    { busy: asking },
  );

  if (state.phase === "empty" && emptyState) return emptyState();

  if (state.phase === "failed" && !state.transient)
    return (
      <div className="ed-page ed-page-message" role="alert">
        <p>{state.failure ?? t(L.failed)}</p>
      </div>
    );

  if (down)
    return (
      <output className="ed-page ed-page-message" aria-busy={!stillTrying}>
        {stillTrying ? (
          <p>{state.phase === "disconnected" ? t(L.disconnected) : (state.failure ?? t(L.stillOpening))}</p>
        ) : null}
      </output>
    );

  const settings = resolveEditorSettings(state.look.settings);
  const path = state.file?.path ?? "";
  const large = state.file ? isLargeFile(state.file.size, settings) : false;
  const saveStatus = state.readOnly
    ? t(L.readOnly)
    : t({ saved: L.saved, edited: L.edited, saving: L.saving, failed: L.statusFailed }[state.status]);
  const toggle = (key: keyof typeof PREFERENCE_KEYS, value: unknown) =>
    void store.setPreference(PREFERENCE_KEYS[key], value);

  return (
    <div className="ed-page" data-status={state.status} data-read-only={state.readOnly}>
      {settings.toolbar ? (
        <header className="ed-toolbar">
          <span className="ed-file">{state.phase === "loading" ? t(L.loading) : fileName(path)}</span>
          <span className={`ed-save ed-save-${state.readOnly ? "read-only" : state.status}`} aria-live="polite">
            {state.phase === "ready" ? saveStatus : ""}
          </span>
          <span className="ed-toolbar-spacer" />
          <button
            type="button"
            className="ed-toggle"
            aria-pressed={settings.wordWrap !== "off"}
            onClick={() => toggle("wordWrap", settings.wordWrap === "off" ? "on" : "off")}
          >
            {t(L.wordWrap)}
          </button>
          <button
            type="button"
            className="ed-toggle"
            aria-pressed={settings.minimap && !large}
            disabled={large}
            onClick={() => toggle("minimap", !settings.minimap)}
          >
            {t(L.minimap)}
          </button>
        </header>
      ) : null}
      {state.conflict ? (
        <div className="ed-banner" role="alert">
          <span>{t(state.conflict.deleted ? L.conflictDeleted : L.conflictChanged)}</span>
          {state.conflict.deleted ? null : (
            // retry-prompt-ok: reading the file from disk again discards the person's unsaved edits; Keep Mine is the other answer.
            <button type="button" className="ed-button" onClick={() => store.reloadFromDisk()}>
              {t(L.reload)}
            </button>
          )}
          <button type="button" className="ed-button ed-button-primary" onClick={() => void store.keepMine()}>
            {t(L.keep)}
          </button>
        </div>
      ) : null}
      {state.readOnly && state.readOnlyReason && state.phase === "ready" ? (
        <div className="ed-note">{t(READ_ONLY_NOTE[state.readOnlyReason])}</div>
      ) : null}
      {large && state.phase === "ready" ? <div className="ed-note">{t(L.largeNotice)}</div> : null}
      {state.unavailable && state.phase === "ready" ? <output className="ed-note">{state.unavailable}</output> : null}
      <div className="ed-frame">
        <div className="ed-host" ref={editorRef} />
        {find ? <EditorFindBar find={find} strings={strings} /> : null}
      </div>
      {((settings.statusBar && view) || (settings.vimMode && vimLine)) && state.phase === "ready" ? (
        // With `editor.vimMode` the bar shows vim's mode line (and its `:` prompt) even when
        // `editor.statusBar` is off.
        <footer className="ed-status" data-vim={settings.vimMode && vimLine ? "" : undefined}>
          {vimLine ? (
            <div
              className="ed-vim-slot"
              ref={(slot) => {
                // Moved only once: moving it again would blur an open `:` prompt.
                if (slot && vimLine.parentNode !== slot) slot.replaceChildren(vimLine);
              }}
            />
          ) : null}
          {settings.statusBar && view ? (
            <>
              <span>{strings.format(L.position, String(view.line), String(view.column))}</span>
              <span>{strings.format(view.insertSpaces ? L.spaces : L.tabs, String(view.tabSize))}</span>
              <span>{view.bom ? t(L.utf8Bom) : "UTF-8"}</span>
              <span>{view.eol === "mixed" ? t(L.mixed) : view.eol}</span>
              <span>{view.language === "text" ? t(L.plainText) : view.languageName}</span>
            </>
          ) : null}
        </footer>
      ) : null}
    </div>
  );
}
