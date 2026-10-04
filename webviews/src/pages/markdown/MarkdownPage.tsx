// The markdown editor page (plans/cmux-next/diff-host.md S6). State lives in `MarkdownStore`; this
// file renders it: a toolbar (file, save status, rich text or source), the conflict banner, and the
// editor or the source text. The editor mounts through a callback ref. Cmd/Ctrl chords (Cmd-S)
// come from the app's key dispatcher as page commands, never from page key handlers.
import { useSyncExternalStore, type ChangeEvent, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { L } from "./strings";
import type { MarkdownMode, MarkdownStore } from "./store";

export interface MarkdownPageProps {
  store: MarkdownStore;
  strings: Strings;
  /** Mounts the rich text editor into its element (and unmounts it on null). */
  editorRef: (element: HTMLDivElement | null) => void;
  /** The page with no file (store phase `empty`): the viewer empty state. */
  emptyState?: () => ReactNode;
}

function fileName(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}

export function MarkdownPage({ store, strings, editorRef, emptyState }: MarkdownPageProps) {
  const state = useSyncExternalStore(store.subscribe, store.getState);
  const { t } = strings;

  if (state.phase === "empty" && emptyState) return emptyState();

  if (state.phase === "disconnected" || state.phase === "failed") {
    return (
      <div className="md-page md-page-message" role="alert">
        <p>{t(state.phase === "disconnected" ? L.disconnected : L.failed)}</p>
        <button type="button" className="md-button" onClick={() => void store.start()}>
          {t(L.retry)}
        </button>
      </div>
    );
  }

  const status = state.readOnly
    ? t(L.readOnly)
    : t({ saved: L.saved, edited: L.edited, saving: L.saving, failed: L.statusFailed }[state.status]);
  const modes: MarkdownMode[] = ["rich", "source"];
  const path = state.config?.path ?? "";

  return (
    <div className="md-page" data-mode={state.mode} data-status={state.status} data-read-only={state.readOnly}>
      <header className="md-toolbar">
        <span className="md-file" title={path}>
          {state.phase === "loading" ? t(L.loading) : fileName(path)}
        </span>
        <span
          className={`md-status md-status-${state.readOnly ? "read-only" : state.status}`}
          title={state.readOnly ? t(L.readOnlyHelp) : state.status === "failed" ? t(L.saveFailed) : undefined}
          aria-live="polite"
        >
          {state.phase === "ready" ? status : ""}
        </span>
        <fieldset className="md-mode" aria-label={t(L.modeLabel)}>
          {modes.map((mode) => (
            <button
              key={mode}
              type="button"
              aria-pressed={state.mode === mode}
              className="md-mode-button"
              onClick={() => store.setMode(mode)}
            >
              {t(mode === "rich" ? L.rich : L.source)}
            </button>
          ))}
        </fieldset>
      </header>
      {state.conflict ? (
        <div className="md-banner" role="alert">
          <span>{t(state.conflict.deleted ? L.conflictDeleted : L.conflictChanged)}</span>
          {state.conflict.deleted ? null : (
            <button type="button" className="md-button" onClick={() => store.reloadFromDisk()}>
              {t(L.reload)}
            </button>
          )}
          <button type="button" className="md-button md-button-primary" onClick={() => void store.keepMine()}>
            {t(L.keep)}
          </button>
        </div>
      ) : null}
      {state.readOnly && state.phase === "ready" ? <div className="md-note">{t(L.readOnlyHelp)}</div> : null}
      <main className="md-scroll">
        <div className="md-doc" ref={editorRef} hidden={state.mode !== "rich"} />
        {state.mode === "source" ? (
          <SourceEditor
            key={state.revision}
            value={state.source}
            readOnly={state.readOnly}
            label={t(L.source)}
            onChange={(text) => store.setSource(text)}
          />
        ) : null}
      </main>
    </div>
  );
}

function SourceEditor({
  value,
  readOnly,
  label,
  onChange,
}: {
  value: string;
  readOnly: boolean;
  label: string;
  onChange(text: string): void;
}) {
  return (
    <textarea
      className="md-source"
      aria-label={label}
      spellCheck={false}
      readOnly={readOnly}
      value={value}
      onChange={(event: ChangeEvent<HTMLTextAreaElement>) => onChange(event.target.value)}
    />
  );
}
