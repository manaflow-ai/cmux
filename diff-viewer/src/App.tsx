import { useRef } from "react";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "./labels";
import { startDiffViewer } from "./viewer-controller";
import type { DiffViewerConfig } from "./types";
import type { DiffViewerLabelResolver } from "./labels";

type ConfigProps = {
  config: DiffViewerConfig;
};

type ShellProps = ConfigProps & {
  label: DiffViewerLabelResolver;
};

const fileSkeletonWidths = ["82%", "64%", "76%", "58%", "70%", "46%"];
const diffSkeletonWidths = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];

function LoadingFileList() {
  return (
    <div className="diff-loading-placeholder" aria-hidden="true">
      {fileSkeletonWidths.map((width, index) => (
        <div key={`${width}-${index}`} className="grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]">
          <span className="size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" />
          <span className="h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          <span className="h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" style={{ width: index % 2 === 0 ? "34px" : "24px" }} />
        </div>
      ))}
    </div>
  );
}

function LoadingDiffSkeleton() {
  return (
    <div className="diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3" aria-hidden="true">
      <div className="mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3">
        <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" />
        <span className="h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" />
        <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" />
      </div>
      <div className="space-y-[13px] px-3 py-1">
        {diffSkeletonWidths.map((width, index) => (
          <div key={`${width}-${index}`} className="grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4">
            <span className="h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" />
            <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          </div>
        ))}
      </div>
    </div>
  );
}

function LoadingLayer({ config, label }: ShellProps) {
  return (
    <div id="loading-layer" aria-live="polite">
      <div id="status">
        <span id="status-icon" aria-hidden="true" />
        <span id="status-text">{config.payload?.statusMessage ?? label("loadingDiff")}</span>
      </div>
      <LoadingDiffSkeleton />
    </div>
  );
}

function SourceControls({ label }: ShellProps) {
  return (
    <div className="toolbar-left flex min-w-0 items-center gap-1.5">
      <select id="source-select" aria-label={label("diffTarget")} hidden />
      <select id="repo-select" aria-label={label("repoPath")} hidden />
      <select id="base-select" aria-label={label("branchBase")} hidden />
      <span id="source-detail" />
    </div>
  );
}

function Toolbar({ config, label }: ShellProps) {
  return (
    <header id="toolbar">
      <SourceControls config={config} label={label} />
      <div className="toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5">
        <select id="jump-select" aria-label={label("jumpToFile")} hidden />
      </div>
      <div className="toolbar-actions flex shrink-0 items-center gap-1.5">
        <a
          id="external-link"
          className="toolbar-icon"
          href={config.payload?.externalURL ?? "#"}
          target="_blank"
          rel="noreferrer"
          title={label("openSourceURL")}
          aria-label={label("openSourceURL")}
          hidden
        />
        <button
          id="files-toggle"
          className="toolbar-icon"
          type="button"
          title={label("hideFiles")}
          aria-label={label("hideFiles")}
          aria-pressed="true"
        />
        <button
          id="layout-toggle"
          className="toolbar-icon"
          type="button"
          title={label("switchToUnifiedDiff")}
          aria-label={label("switchToUnifiedDiff")}
        />
        <button
          id="options-button"
          className="toolbar-icon"
          type="button"
          title={label("options")}
          aria-label={label("options")}
          aria-expanded="false"
          aria-haspopup="menu"
        />
      </div>
      <div id="options-menu" role="menu" aria-label={label("options")} hidden />
    </header>
  );
}

function FilesSidebar({ label }: ShellProps) {
  return (
    <aside id="files-sidebar" aria-label={label("changedFiles")}>
      <div id="files-header">
        <span id="files-title">
          <span>{label("files")}</span>
          <span id="files-count" />
        </span>
        <span id="files-header-actions">
          <button
            id="file-search-toggle"
            type="button"
            title={label("showFileSearch")}
            aria-label={label("showFileSearch")}
            aria-pressed="false"
          />
          <button
            id="file-collapse-toggle"
            type="button"
            title={label("hideFiles")}
            aria-label={label("hideFiles")}
          />
        </span>
      </div>
      <div id="file-list">
        <LoadingFileList />
      </div>
      <div id="files-footer" aria-label={label("diffStats")}>
        <div className="stats-row">
          <span>{label("files")}</span>
          <strong id="stats-files">0</strong>
        </div>
        <div className="stats-row">
          <span>{label("additions")}</span>
          <strong id="stats-added" className="stat-add">+0</strong>
        </div>
        <div className="stats-row">
          <span>{label("deletions")}</span>
          <strong id="stats-deleted" className="stat-del">-0</strong>
        </div>
      </div>
    </aside>
  );
}

export function App({ config }: ConfigProps) {
  const started = useRef(false);
  const label = createDiffViewerLabelResolver(config.payload?.labels, {
    assertMissing: shouldAssertMissingLabels(),
  });
  // React Compiler memoizes this callback ref, so no manual useCallback.
  const rootRef = (node: HTMLDivElement | null) => {
    if (!node || started.current) {
      return;
    }
    started.current = true;
    startDiffViewer(config);
  };

  return (
    <div id="app" ref={rootRef}>
      <Toolbar config={config} label={label} />
      <section id="content">
        <FilesSidebar config={config} label={label} />
        <main id="viewer" aria-label={label("diffViewer")}>
          <LoadingLayer config={config} label={label} />
        </main>
      </section>
    </div>
  );
}
