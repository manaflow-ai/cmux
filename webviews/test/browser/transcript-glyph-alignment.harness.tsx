import { createRoot } from "react-dom/client";
import type { CSSProperties } from "react";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/glass/glass.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/session-info/sessionInfo.css";
import { ToolRow } from "../../src/agent-session/acpmux/conversation/ToolRow";
import { CommandRow } from "../../src/agent-session/acpmux/conversation/CommandRow";
import { TurnFooter, WorkedFor } from "../../src/agent-session/acpmux/conversation/TurnRows";
import { ThoughtRow } from "../../src/agent-session/acpmux/conversation/ThoughtRow";
import { PlanList } from "../../src/agent-session/acpmux/conversation/PlanList";
import { UserBubble } from "../../src/agent-session/acpmux/conversation/UserBubble";
import { ReadReceipt, ReceivedActions } from "../../src/agent-session/acpmux/conversation/MessageActions";
import { TurnActionsContext, type TurnActions } from "../../src/agent-session/acpmux/conversation/turnActions";
import { SessionInfoSection } from "../../src/agent-session/acpmux/session-info/SessionInfoSection";
import { EnvironmentSection } from "../../src/agent-session/acpmux/session-info/EnvironmentSection";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
import type { AcpmuxActivity, AcpmuxRow } from "../../src/agent-session/acpmux/model";

globalThis.__cmuxPaneStrings = { en: strings.en };
document.documentElement.dataset.cmuxMotion = "off";
const themes = {
  dark: { page: "#202124", text: "#f5f5f1", muted: "#c9c9c4", soft: "#95958f" },
  light: { page: "#f7f7f2", text: "#242420", muted: "#55554f", soft: "#77776f" },
} as const;
const selectedTheme = new URLSearchParams(location.search).get("theme") === "light" ? "light" : "dark";
for (const [key, value] of Object.entries({
  "--agent-page-bg": themes[selectedTheme].page,
  "--agent-text": themes[selectedTheme].text,
  "--agent-muted": themes[selectedTheme].muted,
  "--agent-soft": themes[selectedTheme].soft,
  "--font-ui": "system-ui",
}))
  document.documentElement.style.setProperty(key, value);
const row: AcpmuxRow = {
  id: "glyph-prompt",
  version: 1,
  kind: "user",
  at: Date.now() - 300_000,
  text: "Check the alignment of this sent message.",
};
const item: AcpmuxActivity = {
  kind: "tool",
  text: "",
  tool: {
    id: "glyph-tool",
    title: "Run focused checks",
    description: "Run focused checks",
    kind: "execute",
    status: "completed",
    command: "echo checks",
    startedAt: 1000,
    endedAt: 7000,
  },
};
const actions: TurnActions = {
  branches: {
    of: new Map([["glyph-versioned-prompt", { sessions: ["version-a", "version-b", "version-c"], index: 1 }]]),
    open: () => undefined,
  },
  retry: () => undefined,
  retryWith: {
    models: [
      { id: "model-a", name: "Model A" },
      { id: "model-b", name: "Model B" },
    ],
    current: "model-a",
    retry: () => undefined,
  },
};

function App() {
  const params = new URLSearchParams(location.search);
  const theme = params.get("theme") === "light" ? "light" : "dark";
  const height = params.get("height") === "40" ? 40 : 28;
  const colors = themes[theme];
  if (params.has("narrow")) {
    return (
      <main className="acpmux-shell" style={{ width: "320px", padding: "16px", boxSizing: "border-box" }}>
        <div className="acpmux-row" data-auth-footer style={{ position: "relative", left: 0, right: 0, width: "100%" }}>
          <TurnActionsContext.Provider
            value={{
              reauthenticate: () => undefined,
              transferCloudCredentials: async () => undefined,
              route: { name: "Claude Code", harness: "claude", hostKind: "cloud" },
            }}
          >
            <TurnFooter
              row={{
                ...row,
                kind: "turnSummary",
                status: "failed",
                folded: true,
                error: "401 Unauthorized",
                text: undefined,
                retryRowId: row.id,
                prompt: row.text,
              }}
            />
          </TurnActionsContext.Provider>
        </div>
      </main>
    );
  }
  return (
    <main
      className="acpmux-shell glyph-alignment-fixture"
      data-theme={theme}
      style={
        {
          "--agent-page-bg": colors.page,
          "--agent-text": colors.text,
          "--agent-muted": colors.muted,
          "--agent-soft": colors.soft,
          "--agent-diff-add": theme === "dark" ? "#91c99c" : "#256c37",
          "--font-ui": "system-ui",
          "--fixture-row-height": `${height}px`,
          display: "flex",
          flexDirection: "column",
          padding: "24px",
          gap: "12px",
          height: "auto",
        } as CSSProperties
      }
    >
      <style>{`
        body { margin: 0; background: ${colors.page}; }
        .glyph-alignment-fixture .fixture-rhythm > .cv-tool,
        .glyph-alignment-fixture .fixture-rhythm > .cv-worked { height: var(--fixture-row-height); }
        .glyph-alignment-fixture .cv-user__actions,
        .glyph-alignment-fixture .cv-received-actions,
        .glyph-alignment-fixture .cv-command__ok,
        .glyph-alignment-fixture .cv-command__time { opacity: 1; transition: none; }
        .glyph-alignment-fixture .fixture-received { position: static; min-height: 0; padding: 0; }
        .glyph-alignment-fixture .fixture-read { display: flex; align-items: center; gap: 8px; line-height: 24px; }
      `}</style>
      <TurnActionsContext.Provider value={actions}>
        <div className="cv-user" data-footer-row>
          <UserBubble row={row} text={row.text!} />
        </div>
        <div className="cv-user" data-version-footer-row>
          <UserBubble row={{ ...row, id: "glyph-versioned-prompt" }} text="The same footer with message versions." />
        </div>
        <div className="fixture-rhythm" data-glyph-row="tool">
          <ToolRow item={item} />
        </div>
        <div className="fixture-rhythm" data-glyph-row="command">
          <CommandRow item={{ ...item, tool: { ...item.tool!, id: "glyph-command" } }} />
        </div>
        <div className="fixture-rhythm" data-glyph-row="worked">
          <WorkedFor
            row={{ ...row, kind: "turnSummary", durationMs: 6000, status: "completed" }}
            expanded={false}
            onToggle={() => undefined}
          />
        </div>
        <div className="fixture-rhythm" data-glyph-row="thought">
          <ThoughtRow
            id="glyph-thought"
            item={{ kind: "thought", text: "Inspecting the completed checks.", startedAt: 1000, endedAt: 7000 }}
          />
        </div>
        <div data-glyph-row="plan">
          <PlanList ended entries={[{ content: "The completed plan step", status: "completed" }]} />
        </div>
        <div data-glyph-row="session-info">
          <EnvironmentSection machineName="Studio" />
          <SessionInfoSection
            id="glyph-session-info"
            title="Session Info"
            icon="status.complete"
            open={false}
            onOpenChange={() => undefined}
          />
        </div>
        <div className="fixture-read" data-glyph-row="read">
          <ReadReceipt row={row} />
          <span data-read-label>Sent and read</span>
        </div>
        <div className="fixture-received" data-received-row="nonretryable">
          <ReceivedActions row={row} />
        </div>
        <div className="acpmux-row fixture-received" data-retryable data-received-row="retryable">
          <ReceivedActions row={row} />
        </div>
      </TurnActionsContext.Provider>
    </main>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
