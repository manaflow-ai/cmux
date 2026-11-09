// l10n-allow-file: gallery fixtures (stage buttons), not shipped UI.
// The tucked composer hat (subagents/TrayPullTab.tsx) over a stand-in composer card, with stage
// buttons (outside the pane, for the play script and a person) that set how much runs: none (the
// hat is just the chevron, centred on the composer), a count, one more, or a chat waiting on you.
// Leo, 2026-11-07: "if there's no running work, it should just be centered, right? But when there
// is a number, it can, like, you know, grow into that." Arms: composerHat.experiment.ts (view Compare
// arms); the arms that did not ship draw from composerHatArms.css.
import { useState, type CSSProperties } from "react";
import type { TrayHandleSide } from "../../agent-session/acpmux/chatDisplay";
import { TrayPullTab } from "../../agent-session/acpmux/subagents/TrayPullTab";
import "./composerHatArms.css";

export function ComposerHatStage({
  start = 0,
  waits = false,
  before = false,
  side = "middle",
}: {
  start?: number;
  waits?: boolean;
  /** As before the line stopped at the hat: a spacer between the hat and the composer breaks the
   *  `.acpmux-tray-pull + .acpmux-composer` pairing, so the card's top line runs under the pill. */
  before?: boolean;
  /** Where the handle sits on the card's top edge (agentPane.display.trayHandle). */
  side?: TrayHandleSide;
}) {
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
          <TrayPullTab chat="gallery-chat" waiting={waiting} running={running} working={false} side={side} />
          {before && <span hidden />}
          {/* The real card's classes, so its ring and lit top rim (composerStates.css) are the
              line the hat sits on (Leo, 2026-11-09: "theres a line behind the hat toggle"). */}
          <div className="acpmux-composer">
            <div
              className="ui-glass ui-glass-floats ui-glass-material acpmux-composer-box"
              data-stage-composer=""
              style={{ height: 72, background: "var(--acpmux-composer-tray)" }}
            />
          </div>
        </div>
      </main>
    </div>
  );
}
