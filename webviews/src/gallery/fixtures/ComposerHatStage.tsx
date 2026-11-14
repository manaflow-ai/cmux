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

/** What the pill sits on: the card itself, queued prompts over it, or Codex's location strip (its
 *  tray, 22 px in from the card's sides, composerLook.css). */
export type ComposerHatSurface = "card" | "queue" | "codex-strip";

/** Where the pill sits on the card's line, for comparing (composerHatArms.css): as shipped, 2px over
 *  it (`none`), centred on it (`seated`), standing on it (`perched`), or as before Leo's 2026-11-11
 *  ask, with its 8px stubs beside it (`before`). */
export type ComposerHatBridge = "none" | "seated" | "perched" | "before";

export function ComposerHatStage({
  start = 0,
  waits = false,
  before = false,
  side = "middle",
  surface = "card",
  narrow = false,
  tucked = true,
  bridge = "none",
}: {
  start?: number;
  waits?: boolean;
  /** As before the line stopped at the hat: a spacer between the hat and the composer breaks the
   *  `.acpmux-tray-pull + .acpmux-composer` pairing, so the card's top line runs under the pill. */
  before?: boolean;
  /** Where the handle sits on the card's top edge (agentPane.display.trayHandle). */
  side?: TrayHandleSide;
  surface?: ComposerHatSurface;
  /** A pane under the composer's narrow step (under 298 px of column, composerLocation.css): the
   *  card and the queue reach 8 px past the column the tab sits in. */
  narrow?: boolean;
  /** Whether the hat starts tucked (the pull tab shown); the Tuck button tucks it while work runs. */
  tucked?: boolean;
  bridge?: ComposerHatBridge;
}) {
  const [running, setRunning] = useState(start);
  const [waiting, setWaiting] = useState(waits ? 1 : 0);
  const [isTucked, setTucked] = useState(tucked);
  const set = (next: number, wait = 0) => {
    setRunning(next);
    setWaiting(wait);
  };
  // In the pane's shell, as App.tsx draws it: the card's edge and fill (--acpmux-composer-edge,
  // --acpmux-composer-tray) are the shell's, so without it the card drew no ring at all.
  return (
    <div className="acpmux-shell" style={{ height: "100vh" }}>
      <div
        style={{ display: "flex", flexDirection: "column", flex: 1, minWidth: 0, background: "var(--agent-page-bg)" }}
      >
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
          <button type="button" data-stage="tuck" onClick={() => setTucked(!isTucked)}>
            Tuck the hat
          </button>
        </div>
        <main
          className="acpmux-main"
          data-dock="float"
          style={{ position: "relative", flex: 1, minHeight: 0, display: "flex", flexDirection: "column" }}
        >
          <div style={{ flex: 1 }} />
          <div
            className="acpmux-dock"
            data-stage-bridge={bridge === "none" ? undefined : bridge}
            style={{ "--cv-inset": "16px", ...(narrow ? { width: 300 } : {}) } as CSSProperties}
          >
            {isTucked && (
              <TrayPullTab chat="gallery-chat" waiting={waiting} running={running} working={false} side={side} />
            )}
            {before && <span hidden />}
            {/* The real card's classes, so its ring and lit top rim (composerStates.css) are the
                line the hat sits on (Leo, 2026-11-09: "theres a line behind the hat toggle"). */}
            <div className="acpmux-composer" data-composer-look={surface === "codex-strip" ? "codex" : undefined}>
              {/* The part the pill sits on, when it is not the card (data-stage-top, for the test). */}
              {surface === "queue" && (
                <ol className="ui-glass ui-glass-floats acpmux-composer-queue" data-stage-top="">
                  <li className="acpmux-queued">
                    <button type="button" className="acpmux-queued-text">
                      <span className="acpmux-queued-clamp">Then run the narrow pane tests</span>
                    </button>
                  </li>
                </ol>
              )}
              {surface === "codex-strip" && (
                <div className="acpmux-composer-strip" data-stage-top="">
                  <span className="acpmux-composer-context">~/Projects/cmux</span>
                </div>
              )}
              <div
                className="ui-glass ui-glass-floats ui-glass-material acpmux-composer-box"
                data-stage-composer=""
                // No fill of its own: the card's glass tint (composerStates.css) is the real card's. An
                // inline opaque fill under its backdrop-filter is opaque glass (accent-glass-invariants).
                style={{ height: 72 }}
              />
            </div>
          </div>
        </main>
      </div>
    </div>
  );
}
