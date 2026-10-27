// The markdown editor page (plans/cmux-next/diff-host.md S6). State lives in `MarkdownStore`; this
// file renders it: a toolbar (file, save status, rich text or source), the conflict banner, and the
// editor or the source text. The editor mounts through a callback ref. Cmd/Ctrl chords (Cmd-S)
// come from the app's key dispatcher as page commands, never from page key handlers.
import { lazy, Suspense, useRef, useState, useSyncExternalStore, type ChangeEvent, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { Toolbar, ToolbarButton, ToolbarGroup, ToolbarToggleGroup } from "../../ui/Toolbar";
import type { LinkOverlays } from "./overlays";
import { L } from "./strings";
import type { MarkdownReadOnlyReason } from "./host";
import type { MarkdownMode, MarkdownStore } from "./store";
import type { ReadingSettingsActions } from "./ReadingSettings";
import { toolbarFileLabel } from "./toolbarFile";

/** The note that says why a file is read only. */
const READ_ONLY_NOTE: Record<MarkdownReadOnlyReason, string> = {
  outside: L.readOnlyOutside,
  encoding: L.readOnlyEncoding,
  binary: L.readOnlyBinary,
  permission: L.readOnlyPermission,
  transcript: L.readOnlyTranscript,
};

// The hover card and link popover load after the page (their Base UI parts are not on the open path).
const LinkOverlayHost = lazy(() => import("./linkOverlays").then((module) => ({ default: module.LinkOverlayHost })));
// The Reading Settings popover loads on its first open.
const ReadingSettings = lazy(() => import("./ReadingSettings").then((module) => ({ default: module.ReadingSettings })));

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
  /** The Reading Settings popover's writes (no popover button without them). */
  reading?: ReadingSettingsActions;
}

export function MarkdownPage({
  store,
  strings,
  editorRef,
  emptyState,
  overlays,
  onBack,
  onForward,
  reading,
}: MarkdownPageProps) {
  const state = useSyncExternalStore(store.subscribe, store.getState);
  const [readingOpen, setReadingOpen] = useState(false);
  const readingAnchor = useRef<HTMLSpanElement | null>(null);
  const { t } = strings;

  if (state.phase === "empty" && emptyState) return emptyState();

  if (state.phase === "disconnected" || state.phase === "failed") {
    return (
      <div className="md-page md-page-message" role="alert">
        <p>
          {state.phase === "failed" && state.failure
            ? state.failure
            : t(state.phase === "disconnected" ? L.disconnected : L.failed)}
        </p>
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
  const readOnlyNote = state.readOnlyReason ? t(READ_ONLY_NOTE[state.readOnlyReason]) : undefined;
  const modes: MarkdownMode[] = ["rich", "source"];
  const fileLabel = toolbarFileLabel(
    state.config,
    { loading: state.phase === "loading", navigating: state.navigating },
    t(L.loading),
  );

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
          {/* The native omnibar's Back and Forward stand in for these when it is above the page. */}
          {!state.config?.omnibar && (state.canBack || state.canForward) ? (
            <ToolbarGroup>
              <ToolbarButton
                className="md-history-button"
                label={t(L.back)}
                tooltip={false}
                disabled={!state.canBack}
                onPress={onBack}
              >
                ‹
              </ToolbarButton>
              <ToolbarButton
                className="md-history-button"
                label={t(L.forward)}
                tooltip={false}
                disabled={!state.canForward}
                onPress={onForward}
              >
                ›
              </ToolbarButton>
            </ToolbarGroup>
          ) : null}
          {/* The span stays as the flexible gap that keeps status, mode and Aa on the right. */}
          <span className="md-file">{fileLabel ?? ""}</span>
          <span
            className={`md-status md-status-${state.readOnly ? "read-only" : state.status}`}
            // tooltip-allow: why the file is read-only or failed to save
            title={state.readOnly ? readOnlyNote : state.status === "failed" ? t(L.saveFailed) : undefined}
            aria-live="polite"
          >
            {state.phase === "ready" ? status : ""}
          </span>
          {!state.readOnly && state.mode !== "source" ? (
            <ToolbarButton className="md-edit-button" label={t(L.edit)} onPress={() => store.setMode("source")}>
              {t(L.edit)}
            </ToolbarButton>
          ) : null}
          <ToolbarToggleGroup
            className="md-mode"
            label={t(L.modeLabel)}
            value={state.mode}
            options={modes.map((mode) => ({ value: mode, label: t(mode === "rich" ? L.rich : L.source) }))}
            onValueChange={(mode) => store.setMode(mode as MarkdownMode)}
          />
          {reading ? (
            <span className="md-reading-anchor" ref={readingAnchor}>
              <ToolbarButton
                className="md-reading-button"
                label={t(L.readingButton)}
                pressed={readingOpen}
                onPress={() => setReadingOpen((open) => !open)}
              >
                Aa
              </ToolbarButton>
            </span>
          ) : null}
        </Toolbar>
      </header>
      {reading && readingOpen ? (
        <Suspense fallback={null}>
          <ReadingSettings
            open={readingOpen}
            onOpenChange={setReadingOpen}
            anchor={readingAnchor.current}
            settings={state.look.settings}
            strings={strings}
            actions={reading}
          />
        </Suspense>
      ) : null}
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
      {state.readOnly && readOnlyNote && state.phase === "ready" ? <div className="md-note">{readOnlyNote}</div> : null}
      {state.unavailable && state.phase === "ready" ? <output className="md-note">{state.unavailable}</output> : null}
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
