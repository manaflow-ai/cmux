import React from "react";
import { t, type StringKey } from "./i18n";

export type AgentPaneTool = "terminal" | "diff" | "browser";

const TOOL_LABELS: Record<AgentPaneTool, StringKey> = {
  terminal: "pane.tool.terminal",
  diff: "pane.tool.diff",
  browser: "pane.tool.browser",
};

const TOOL_SHORTCUTS: Record<AgentPaneTool, string> = {
  terminal: "⇧⌘T",
  diff: "⇧⌘D",
  browser: "⇧⌘B",
};

function TerminalIcon() {
  return (
    <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true">
      <path
        d="m3.25 4.5 3 3-3 3M7.75 10.5h4"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.35"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function DiffIcon() {
  return (
    <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true">
      <path
        d="M4 2.75h8v10.5H4zM6.5 5.25h3M6.5 8h3M6.5 10.75h1.75"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function BrowserIcon() {
  return (
    <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true">
      <circle cx="8" cy="8" r="5.25" fill="none" stroke="currentColor" strokeWidth="1.25" />
      <path
        d="M2.95 6.25h10.1M8 2.75c1.35 1.45 2.05 3.2 2.05 5.25S9.35 11.8 8 13.25c-1.35-1.45-2.05-3.2-2.05-5.25S6.65 4.2 8 2.75Z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.05"
      />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path d="m4 4 8 8M12 4l-8 8" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" />
    </svg>
  );
}

function BackIcon() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d="m9.75 3.5-4.5 4.5 4.5 4.5M5.5 8h6"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function ForwardIcon() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d="m6.25 3.5 4.5 4.5-4.5 4.5M10.5 8h-6"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function GlobeIcon() {
  return (
    <svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true">
      <circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" strokeWidth="1.3" />
      <path
        d="M3.8 9.25h16.4M3.8 14.75h16.4M12 3.5c2.2 2.35 3.3 5.18 3.3 8.5S14.2 18.15 12 20.5c-2.2-2.35-3.3-5.18-3.3-8.5S9.8 5.85 12 3.5Z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.1"
      />
    </svg>
  );
}

function toolIcon(tool: AgentPaneTool) {
  if (tool === "terminal") return <TerminalIcon />;
  if (tool === "diff") return <DiffIcon />;
  return <BrowserIcon />;
}

export function PaneToolToggle({
  tool,
  active,
  onToggle,
}: {
  tool: AgentPaneTool;
  active: boolean;
  onToggle: () => void;
}) {
  const label = t(TOOL_LABELS[tool]);
  const shortcut = TOOL_SHORTCUTS[tool];
  return (
    <button
      type="button"
      className="acpmux-pane-tool"
      aria-label={label}
      aria-pressed={active}
      title={`${label} ${shortcut}`}
      onClick={onToggle}
    >
      {toolIcon(tool)}
    </button>
  );
}

export function PaneToolToggles({
  active,
  onToggle,
}: {
  active?: AgentPaneTool;
  onToggle: (tool: AgentPaneTool) => void;
}) {
  return (
    <div className="acpmux-pane-tools" role="toolbar" aria-label={t("pane.tools")}>
      {(["terminal", "diff", "browser"] as AgentPaneTool[]).map((tool) => (
        <PaneToolToggle key={tool} tool={tool} active={active === tool} onToggle={() => onToggle(tool)} />
      ))}
    </div>
  );
}

export function PaneSidePanel({ kind, onClose }: { kind: AgentPaneTool; onClose: () => void }) {
  const label = t(TOOL_LABELS[kind]);
  return (
    <section className={`acpmux-side-panel acpmux-${kind}-panel`} aria-label={label} data-panel={kind}>
      <header className="acpmux-side-panel-header">
        <strong>{label}</strong>
        <button
          type="button"
          className="acpmux-side-panel-close"
          aria-label={t("pane.panel.close", { name: label })}
          title={t("pane.panel.close", { name: label })}
          onClick={onClose}
        >
          <CloseIcon />
        </button>
      </header>
      {kind === "browser" ? <BrowserPanelBody /> : kind === "terminal" ? <TerminalPanelBody /> : <DiffEmptyBody />}
    </section>
  );
}

function TerminalPanelBody() {
  return (
    <div className="acpmux-terminal-panel-body">
      <div className="acpmux-terminal-prompt" aria-hidden="true">
        <span>›</span>
        <span className="acpmux-terminal-caret" />
      </div>
      <p>{t("pane.terminal.empty")}</p>
    </div>
  );
}

function DiffEmptyBody() {
  return <div className="acpmux-side-panel-empty">{t("pane.diff.empty")}</div>;
}

function BrowserPanelBody() {
  return (
    <>
      <div className="acpmux-browser-toolbar">
        <button
          type="button"
          className="acpmux-browser-nav"
          aria-label={t("pane.browser.back")}
          title={t("pane.browser.back")}
          disabled
        >
          <BackIcon />
        </button>
        <button
          type="button"
          className="acpmux-browser-nav"
          aria-label={t("pane.browser.forward")}
          title={t("pane.browser.forward")}
          disabled
        >
          <ForwardIcon />
        </button>
        <input aria-label={t("pane.browser.url")} placeholder={t("pane.browser.urlPlaceholder")} />
      </div>
      <div className="acpmux-browser-empty">
        <GlobeIcon />
        <strong>{t("pane.browser.empty")}</strong>
        <p>{t("pane.browser.description")}</p>
        <button type="button" className="acpmux-browser-detect">
          {t("pane.browser.detect")}
        </button>
      </div>
    </>
  );
}
