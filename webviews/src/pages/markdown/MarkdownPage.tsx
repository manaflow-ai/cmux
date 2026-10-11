// The markdown editor page (plans/cmux-next/diff-host.md S6). State lives in `MarkdownStore`; this
// file renders it: a toolbar (file, save status, rich text or source), the conflict banner, and the
// editor or the source text. The editor mounts through a callback ref. Cmd/Ctrl chords (Cmd-S)
// come from the app's key dispatcher as page commands, never from page key handlers.
import { lazy, Suspense, useSyncExternalStore, type ChangeEvent, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { Toolbar, ToolbarButton, ToolbarGroup, ToolbarToggleGroup } from "../../ui/Toolbar";
import type { LinkOverlays } from "./overlays";
import { L } from "./strings";
import type { MarkdownMode, MarkdownStore } from "./store";

// The hover card and link popover load after the page (their Base UI parts are not on the open path).
const LinkOverlayHost = lazy(() => import("./linkOverlays").then((module) => ({ default: module.LinkOverlayHost })));

export interface MarkdownPageProps {
  store: MarkdownStore;
  strings: Strings;
  /** Mounts the rich text editor into its element (and unmounts it on null). */
  editorRef: (element: HTMLDivElement | null) => void;
  /** The page with no file (store phase `empty`): the viewer empty state. */
  emptyState?: () => ReactNode;
  /** The editor's link hover card and popover, rendered here so they share the page's root. */
  overlays?: LinkOverlays;
  /** The link history (the same as the `back` and `forward` page commands). */
  onBack?(): void;
  onForward?(): void;
}

function fileName(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}

export function MarkdownPage({
  store,
  strings,
  editorRef,
  emptyState,
  overlays,
  onBack,
  onForward,
}: MarkdownPageProps) {
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

  // A followed link names its file at once and says it is loading (zero-latency rule a); a file
  // that did not open says so in the same place.
  const status = state.navigating
    ? t(L.loading)
    : state.navigationFailed
      ? t(L.failed)
      : state.readOnly
        ? t(L.readOnly)
        : t({ saved: L.saved, edited: L.edited, saving: L.saving, failed: L.statusFailed }[state.status]);
  const modes: MarkdownMode[] = ["rich", "source"];
  const path = state.config?.path ?? "";

  return (
    <div
      className="md-page"
      data-mode={state.mode}
      data-status={state.status}
      data-read-only={state.readOnly}
      data-navigating={state.navigating != null || undefined}
    >
      <header className="md-toolbar-host">
        <Toolbar className="md-toolbar" label={t(L.toolbarLabel)}>
          {state.canBack || state.canForward ? (
            <ToolbarGroup>
              <ToolbarButton className="md-history-button" label={t(L.back)} disabled={!state.canBack} onPress={onBack}>
                ‹
              </ToolbarButton>
              <ToolbarButton
                className="md-history-button"
                label={t(L.forward)}
                disabled={!state.canForward}
                onPress={onForward}
              >
                ›
              </ToolbarButton>
            </ToolbarGroup>
          ) : null}
          <span className="md-file" title={path}>
            {state.phase === "loading" ? t(L.loading) : fileName(state.navigating ?? path)}
          </span>
          <span
            className={`md-status md-status-${state.readOnly ? "read-only" : state.status}`}
            title={state.readOnly ? t(L.readOnlyHelp) : state.status === "failed" ? t(L.saveFailed) : undefined}
            aria-live="polite"
          >
            {state.phase === "ready" ? status : ""}
          </span>
          <ToolbarToggleGroup
            className="md-mode"
            label={t(L.modeLabel)}
            value={state.mode}
            options={modes.map((mode) => ({ value: mode, label: t(mode === "rich" ? L.rich : L.source) }))}
            onValueChange={(mode) => store.setMode(mode as MarkdownMode)}
          />
        </Toolbar>
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
        <div className="md-doc selectable" ref={editorRef} hidden={state.mode !== "rich"} />
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
      {overlays ? (
        <Suspense fallback={null}>
          <LinkOverlayHost overlays={overlays} />
        </Suspense>
      ) : null}
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
