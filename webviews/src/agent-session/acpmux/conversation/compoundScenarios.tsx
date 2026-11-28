// l10n-allow-file: gallery and test fixtures (sample prompts and replies), not shipped UI.
// The compound motions of the agent pane, one scripted case each, for the motion map
// (webviews/test/compound-motion.test.ts) and the gallery (CompoundMotion.gallery.tsx). Leo,
// 2026-11-22: "there are a lot of these possible compound movement situations, esp with folds, that i
// think we can watch for and map out harder to have more cohesive animations."
//
// The pane is the real VirtualTranscript over a chat's history, followed at its latest row, with a
// stand-in for the docked composer: a card whose prompt field grows on the composer's own growth
// event (composer/fieldGrowth.ts), and a queue card the stack can bring. Every case plays on timers,
// as a socket's events land, and names the step its event starts in (EVENT_STEP).
import { useState } from "react";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import { CARD_EMPTY, scriptedHistory } from "./scriptedTurn";
import { turnView } from "./turns";
import { LINE } from "./compoundPlay";

export type { CompoundCase } from "./compoundCases";

/// The empty card's field: one line; the rest of the card is its chrome.
const FIELD_EMPTY = LINE;

export type PaneState = {
  rows: AcpmuxRow[];
  working: boolean;
  sends: number;
  card: number;
  /// A queue card over the composer, px tall (0: none).
  queue: number;
  /// The pane's width share (1: all of it), for the split resize.
  width: number;
};

const expanded = new Set<string>();

/// The pane the cases play in; `bind` hands out its state setter.
export function CompoundPane({
  bind,
  sessionId,
}: {
  bind: (show: (next: Partial<PaneState>) => void) => void;
  sessionId: string;
}) {
  const [now, setState] = useState<PaneState>(() => ({
    rows: scriptedHistory(),
    working: false,
    sends: 0,
    card: CARD_EMPTY,
    queue: 0,
    width: 1,
  }));
  const [dock, setDock] = useState<HTMLElement | null>(null);
  bind((next) => setState((was) => ({ ...was, ...next })));
  return (
    <div className="acpmux-shell" style={{ width: `${now.width * 100}%`, height: "100%" }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={turnView(now.rows, expanded, { working: now.working })}
            sessionId={sessionId}
            working={now.working}
            sends={now.sends}
            jumpButton
            dock={dock}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </div>
        <div ref={setDock} className="acpmux-dock">
          {now.queue > 0 && <div data-compound-queue style={{ height: now.queue }} />}
          <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
            <div className="acpmux-composer-strip-placeholder" />
            <div
              className="acpmux-composer-box"
              data-page-glass="docked composer specimen: the page's glass, as ComposerBox.tsx"
            >
              <div className="acpmux-md-field" style={{ height: now.card - CARD_EMPTY + FIELD_EMPTY }} />
              <div style={{ height: CARD_EMPTY - FIELD_EMPTY }} />
            </div>
          </form>
        </div>
      </div>
    </div>
  );
}
