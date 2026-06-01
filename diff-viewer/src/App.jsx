import { useCallback, useRef } from "react";
import { startDiffViewer } from "./legacy-viewer.js";

function label(config, key) {
  return config.payload?.labels?.[key] ?? key;
}

function SourceControls({ config }) {
  return (
    <div className="toolbar-left">
      <select id="source-select" aria-label={label(config, "diffTarget")} hidden />
      <select id="repo-select" aria-label={label(config, "repoPath")} hidden />
      <select id="base-select" aria-label={label(config, "branchBase")} hidden />
      <span id="source-detail" />
    </div>
  );
}

function Toolbar({ config }) {
  return (
    <header id="toolbar">
      <SourceControls config={config} />
      <div className="toolbar-middle">
        <select id="jump-select" aria-label={label(config, "jumpToFile")} hidden />
      </div>
      <div className="toolbar-actions">
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

function FilesSidebar({ config }) {
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
      <div id="file-list" />
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

export function App({ config }) {
  const started = useRef(false);
  const rootRef = useCallback((node) => {
    if (!node || started.current) {
      return;
    }
    started.current = true;
    queueMicrotask(() => startDiffViewer(config));
  }, [config]);

  return (
    <div id="app" ref={rootRef}>
      <Toolbar config={config} />
      <section id="content">
        <FilesSidebar config={config} />
        <main id="viewer" aria-label={label(config, "diffViewer")}>
          <div id="status">{config.payload?.statusMessage ?? label(config, "loadingDiff")}</div>
        </main>
      </section>
    </div>
  );
}
