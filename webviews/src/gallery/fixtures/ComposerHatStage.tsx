// l10n-allow-file: gallery fixtures (stage buttons), not shipped UI.
// The tucked composer hat (subagents/TrayPullTab.tsx) over a stand-in composer card, with stage
// buttons (outside the pane, for the play script and a person) that set how much runs: none (the
// hat is just the chevron, centred on the composer), a count, one more, or a chat waiting on you.
// Leo, 2026-11-07: "if there's no running work, it should just be centered, right? But when there
// is a number, it can, like, you know, grow into that." Arms: composerHat.experiment.ts (view Compare
// arms); the arms that did not ship draw from composerHatArms.css.
import { useState, type CSSProperties } from "react";
import { TrayPullTab } from "../../agent-session/acpmux/subagents/TrayPullTab";
import "./composerHatArms.css";

export function ComposerHatStage({ start = 0, waits = false }: { start?: number; waits?: boolean }) {
  const [running, setRunning] = useState(start);
  const [waiting, setWaiting] = useState(waits ? 1 : 0);
  const set = (next: number, wait = 0) => {
    setRunning(next);
    setWaiting(wait);
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", background: "var(--agent-page-bg)" }}>
      <div
        style={{
          display: "flex",
          gap: "var(--ds-space-2)",
          padding: "var(--ds-space-2)",
          borderBottom: "1px solid var(--agent-border)",
        }}
      >
        <button type="button" data-stage="idle" onClick={() => set(0)}>
          Nothing runs
        </button>
        <button type="button" data-stage="count" onClick={() => set(3)}>
          Three run
        </button>
        <button type="button" data-stage="more" onClick={() => set(running + 1)}>
          One more
        </button>
        <button type="button" data-stage="ten" onClick={() => set(12)}>
          Twelve run
        </button>
        <button type="button" data-stage="waiting" onClick={() => set(running, 1)}>
          One waits on you
        </button>
      </div>
      <main
        className="acpmux-main"
        data-dock="float"
        style={{ position: "relative", flex: 1, minHeight: 0, display: "flex", flexDirection: "column" }}
      >
        <div style={{ flex: 1 }} />
        <div className="acpmux-dock" style={{ "--cv-inset": "16px" } as CSSProperties}>
          <TrayPullTab chat="gallery-chat" waiting={waiting} running={running} working={false} side="middle" />
          <div className="acpmux-composer">
            <div
              className="acpmux-composer-box"
              data-stage-composer=""
              style={{
                margin: "0 16px 16px",
                height: 72,
                borderRadius: 12,
                background: "var(--acpmux-composer-tray)",
                boxShadow: "inset 0 0 0 1px var(--agent-border)",
              }}
            />
          </div>
        </div>
      </main>
    </div>
  );
}
