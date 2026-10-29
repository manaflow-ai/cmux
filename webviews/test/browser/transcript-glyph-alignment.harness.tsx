import { createRoot } from "react-dom/client";
import "../../src/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/inspector/inspector.css";
import type { CSSProperties } from "react";

const themes = {
  dark: { page: "#202124", text: "#f5f5f1", muted: "#c9c9c4", soft: "#95958f" },
  light: { page: "#f7f7f2", text: "#242420", muted: "#55554f", soft: "#77776f" },
} as const;

const mark = (label: string) => (
  <svg aria-label={label} viewBox="0 0 16 16" width="14" height="14" className="fixture-glyph" role="img">
    <circle cx="8" cy="8" r="5" fill="currentColor" />
  </svg>
);

function FixtureRow({ kind, height }: { kind: string; height: number }) {
  const rowStyle = { height: `${height}px` };
  if (kind === "tool") {
    return (
      <div className="cv-tool" data-glyph-row={kind} style={rowStyle}>
        <span className="cv-tool__icon">{mark("tool")}</span>
        <span className="cv-tool__text">Run focused checks</span>
        <span className="cv-tool__detail">done</span>
        <span className="cv-tool__chevron" aria-hidden="true">›</span>
      </div>
    );
  }
  if (kind === "worked") {
    return (
      <div className="cv-worked" data-glyph-row={kind} style={rowStyle}>
        <span className="cv-worked__glyph">{mark("worked")}</span>
        <span className="cv-worked__label">Worked for</span>
      </div>
    );
  }
  if (kind === "received") {
    return (
      <div className="cv-received" data-glyph-row={kind}>
        <div className="cv-received__line" style={rowStyle}>
          <span className="cv-received__icon">{mark("received")}</span>
          <span className="cv-received__name">Received 3</span>
          <span className="cv-received__toggle">Peer update</span>
        </div>
      </div>
    );
  }
  return (
    <div className="acpmux-chat-inspector-row" data-glyph-row={kind} style={rowStyle}>
      <svg aria-label="session info" className="acpmux-row-glyph" viewBox="0 0 24 24" role="img">
        <circle cx="12" cy="12" r="7" fill="currentColor" />
      </svg>
      <span className="acpmux-chat-inspector-row__name">Session Info</span>
      <span className="acpmux-chat-inspector-row__detail">secondary detail</span>
    </div>
  );
}

function FooterRow({ height }: { height: number }) {
  const icon = (label: string) => (
    <svg aria-label={label} viewBox="0 0 16 16" width="16" height="16" role="img">
      <circle cx="8" cy="8" r="5" fill="currentColor" />
    </svg>
  );
  return (
    <div className="cv-message-footer-row" data-footer-row="true" style={{ height: `${height}px` }}>
      <time className="cv-user__time" data-footer-time="true">12s</time>
      <button type="button" className="cv-iconbtn" data-footer-glyph="copy" aria-label="Copy">
        {icon("Copy")}
      </button>
      <button type="button" className="cv-iconbtn" data-footer-glyph="retry" aria-label="Retry">
        {icon("Retry")}
      </button>
      <button type="button" className="cv-iconbtn cv-turn-retry-menu" data-footer-glyph="chevron" aria-label="More models">
        {icon("Chevron")}
      </button>
    </div>
  );
}

function App() {
  const params = new URLSearchParams(location.search);
  const theme = params.get("theme") === "light" ? "light" : "dark";
  const height = params.get("height") === "40" ? 40 : 28;
  const capture = params.get("capture") === "before" ? "before" : "after";
  const colors = themes[theme];
  return (
    <main
      className="acpmux-shell glyph-alignment-fixture"
      data-theme={theme}
      data-capture={capture}
      style={
        {
          "--agent-page-bg": colors.page,
          "--agent-text": colors.text,
          "--agent-muted": colors.muted,
          "--agent-soft": colors.soft,
          "--font-ui": "system-ui",
          "--text-control": "13px",
          "--text-control--letter-spacing": "0",
          "--text-detail": "11px",
          "--text-detail--letter-spacing": "0",
          display: "flex",
          flexDirection: "column",
          alignItems: "stretch",
          gap: "4px",
          padding: "16px",
        } as CSSProperties
      }
    >
      <style>{`
        /* Capture-only baseline: the pre-slot geometry remains available for a synthetic before/after pair. */
        [data-capture="before"] .cv-tool { grid-template-columns: auto minmax(0, 1fr) auto auto; }
        [data-capture="before"] .cv-tool__icon { width: auto; height: auto; }
        [data-capture="before"] .cv-worked { align-items: flex-start; padding-top: 2.5px; }
        [data-capture="before"] .cv-worked__glyph { width: auto; height: 20px; }
        [data-capture="before"] .cv-received__icon { width: 16px; height: auto; }
        [data-capture="before"] .acpmux-row-glyph { width: auto; height: auto; }
      `}</style>
      <FixtureRow kind="tool" height={height} />
      <FixtureRow kind="worked" height={height} />
      <FixtureRow kind="received" height={height} />
      <FixtureRow kind="session-info" height={height} />
      <FooterRow height={height} />
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
