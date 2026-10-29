import { createRoot } from "react-dom/client";
import "../../src/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/inspector/inspector.css";
import type { CSSProperties } from "react";
import { Icon } from "../../src/agent-session/acpmux/icons/Icon";
import { ToolRow } from "../../src/agent-session/acpmux/conversation/ToolRow";
import { WorkedFor } from "../../src/agent-session/acpmux/conversation/TurnRows";
import { PromptActions } from "../../src/agent-session/acpmux/conversation/MessageActions";
import { TurnActionsContext } from "../../src/agent-session/acpmux/conversation/turnActions";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";

const themes = {
  dark: { page: "#202124", text: "#f5f5f1", muted: "#c9c9c4", soft: "#95958f" },
  light: { page: "#f7f7f2", text: "#242420", muted: "#55554f", soft: "#77776f" },
} as const;

function FixtureRow({ kind, height }: { kind: string; height: number }) {
  const rowStyle = { height: `${height}px` };
  if (kind === "tool") {
    return (
      <div className="fixture-tool" data-glyph-row={kind} style={rowStyle}>
        <ToolRow item={{ kind: "tool", text: "", tool: { id: "fixture-check", title: "echo focused checks", kind: "execute", status: "completed", command: "echo focused checks", startedAt: 1000, endedAt: 7000 } }} />
      </div>
    );
  }
  if (kind === "worked") {
    return (
      <div data-glyph-row={kind} style={rowStyle}>
        <WorkedFor row={{ id: "worked-fixture", kind: "worked", at: 1000, durationMs: 6000, status: "completed" } as unknown as AcpmuxRow} expanded={false} onToggle={() => undefined} />
      </div>
    );
  }
  if (kind === "received") {
    return (
      <div className="cv-received" data-glyph-row={kind}>
        <div className="cv-received__line" style={rowStyle}>
          <span className="cv-received__icon"><Check size={16} /></span>
          <span className="cv-received__name">Received 3</span>
          <span className="cv-received__toggle">Peer update</span>
        </div>
      </div>
    );
  }
  return (
    <div className="acpmux-chat-inspector-row" data-glyph-row={kind} style={rowStyle}>
      <Icon name="status.warning" size={16} className="acpmux-row-glyph" />
      <span className="acpmux-chat-inspector-row__name">Session Info</span>
      <span className="acpmux-chat-inspector-row__detail">secondary detail</span>
    </div>
  );
}

function FooterRow({ height }: { height: number }) {
  const row = { id: "footer-fixture", kind: "user", at: Date.now(), text: "Synthetic sent message", resend: "Synthetic sent message" } as unknown as AcpmuxRow;
  return <div data-footer-row="true" style={{ height: `${height}px` }}><TurnActionsContext.Provider value={{ retry: () => undefined, retryWith: { models: [{ id: "model-a", name: "Model A" }, { id: "model-b", name: "Model B" }], current: "model-a", retry: () => undefined } }}><PromptActions row={row} text="Synthetic sent message" /></TurnActionsContext.Provider></div>;
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
        [data-capture="before"] .cv-message-footer-row { min-height: 20px; }
        [data-capture="before"] .cv-message-footer-row > :is(.cv-user__time, .cv-turn-time) { height: 20px; }
        [data-capture="before"] .cv-message-footer-row .cv-iconbtn { width: 20px; height: 20px; }
        [data-capture="before"] .cv-message-footer-row .cv-iconbtn.cv-turn-retry-menu { width: 20px; }
        .glyph-alignment-fixture .fixture-tool > .cv-tool,
        .glyph-alignment-fixture [data-glyph-row="worked"] > .cv-worked { height: 100%; }
        .glyph-alignment-fixture [data-footer-row] > .cv-user__actions { height: 100%; align-items: center; }
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
