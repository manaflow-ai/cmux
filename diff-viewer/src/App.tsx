import { useCallback, useRef } from "react";
import { startDiffViewer } from "./viewer-controller";
import type { DiffViewerConfig } from "./types";

type ConfigProps = {
  config: DiffViewerConfig;
};

function label(config: DiffViewerConfig, key: string): string {
  return config.payload?.labels?.[key] ?? key;
}

const fileSkeletonWidths = ["82%", "64%", "76%", "58%", "70%", "46%"];
const diffSkeletonWidths = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];

function LoadingFileList() {
  return (
    <div className="diff-loading-placeholder p-2" aria-hidden="true">
      {fileSkeletonWidths.map((width, index) => (
        <div key={`${width}-${index}`} className="grid h-[30px] grid-cols-[17px_minmax(0,1fr)_44px] items-center gap-2 rounded-md px-[7px]">
          <span className="size-[17px] rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" />
          <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          <span className="h-3 justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" style={{ width: index % 2 === 0 ? "34px" : "24px" }} />
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

function SourceControls({ config }: ConfigProps) {
  return (
    <div className="toolbar-left flex min-w-0 items-center gap-1.5">
      <select id="source-select" aria-label={label(config, "diffTarget")} hidden />
      <select id="repo-select" aria-label={label(config, "repoPath")} hidden />
      <select id="base-select" aria-label={label(config, "branchBase")} hidden />
      <span id="source-detail" />
    </div>
  );
}

function Toolbar({ config }: ConfigProps) {
  return (
    <header id="toolbar">
      <SourceControls config={config} />
      <div className="toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5">
        <select id="jump-select" aria-label={label(config, "jumpToFile")} hidden />
      </div>
      <div className="toolbar-actions flex shrink-0 items-center gap-1.5">
        <a
          id="external-link"
          className="toolbar-icon"
          href={config.payload?.externalURL ?? "#"}
          target="_blank"
          rel="noreferrer"
          title={label(config, "openSourceURL")}
          aria-label={label(config, "openSourceURL")}
          hidden
        />
        <button
          id="files-toggle"
          className="toolbar-icon"
          type="button"
          title={label(config, "hideFiles")}
          aria-label={label(config, "hideFiles")}
          aria-pressed="true"
        />
        <button
          id="layout-toggle"
          className="toolbar-icon"
          type="button"
          title={label(config, "switchToUnifiedDiff")}
          aria-label={label(config, "switchToUnifiedDiff")}
        />
        <button
          id="options-button"
          className="toolbar-icon"
          type="button"
          title={label(config, "options")}
          aria-label={label(config, "options")}
          aria-expanded="false"
          aria-haspopup="menu"
        />
      </div>
      <div id="options-menu" role="menu" aria-label={label(config, "options")} hidden />
    </header>
  );
}

function FilesSidebar({ config }: ConfigProps) {
  return (
    <aside id="files-sidebar" aria-label={label(config, "changedFiles")}>
      <div id="files-header">
        <span id="files-title">
          <span>{label(config, "files")}</span>
          <span id="files-count" />
        </span>
        <span id="files-header-actions">
          <button
            id="file-search-toggle"
            type="button"
            title={label(config, "showFileSearch")}
            aria-label={label(config, "showFileSearch")}
            aria-pressed="false"
          />
          <button
            id="file-collapse-toggle"
            type="button"
            title={label(config, "hideFiles")}
            aria-label={label(config, "hideFiles")}
          />
        </span>
      </div>
      <div id="file-list">
        <LoadingFileList />
      </div>
      <div id="files-footer" aria-label={label(config, "diffStats")}>
        <div className="stats-row">
          <span>{label(config, "files")}</span>
          <strong id="stats-files">0</strong>
        </div>
        <div className="stats-row">
          <span>{label(config, "additions")}</span>
          <strong id="stats-added" className="stat-add">+0</strong>
        </div>
        <div className="stats-row">
          <span>{label(config, "deletions")}</span>
          <strong id="stats-deleted" className="stat-del">-0</strong>
        </div>
      </div>
    </aside>
  );
}

export function App({ config }: ConfigProps) {
  const started = useRef(false);
  const rootRef = useCallback((node: HTMLDivElement | null) => {
    if (!node || started.current) {
      return;
    }
    started.current = true;
    startDiffViewer(config);
  }, [config]);

  return (
    <div id="app" ref={rootRef}>
      <Toolbar config={config} />
      <section id="content">
        <FilesSidebar config={config} />
        <main id="viewer" aria-label={label(config, "diffViewer")}>
          <div id="status">{config.payload?.statusMessage ?? label(config, "loadingDiff")}</div>
          <LoadingDiffSkeleton />
        </main>
      </section>
    </div>
  );
}
