// l10n-allow-file: deterministic motion fixture labels.
// A tool call opened and closed while the reply streams on under it (Leo, 2026-11-06: "the entire tool
// call expansion apparatus is borked ... things clash with other things with animations going haywire
// ... way too discontinuous and also way too jittery/sensitive. and it's just slow."). Each play runs
// the scripted turn test/tool-toggle-motion.test.ts measures (scriptedTurn.ts `tool-toggle`): a call
// that prints, then the reply's next segment streams while the call's line is clicked open, closed,
// open again and closed 60 ms into that open. The looks (`data-fold-look`, fold.ts FoldLook) compare
// how the toggle folds: `settle`, shipped, on the settle with a turn back retargeted to the travel
// left; `stack`, before, a turn back plays a whole fold again; `quick`, the quick step; `jump`, at once.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import type { FoldLook } from "./fold";
import { CARD_DRAFT, playScriptedTurn, scriptedHistory, TOGGLE_CALL_ID, type ScriptedView } from "./scriptedTurn";
import { turnView } from "./turns";

const expanded = new Set<string>();

function ToolToggleMotionGallery({ look }: { look: FoldLook }) {
  const [view, setView] = useState<Required<ScriptedView>>(() => ({
    rows: scriptedHistory() as AcpmuxRow[],
    working: false,
    sends: 0,
    card: CARD_DRAFT,
  }));
  const [dock, setDock] = useState<HTMLElement | null>(null);
  const [state, setState] = useState<"ready" | "playing" | "settled">("ready");
  const play = () => {
    if (state === "playing") return;
    setState("playing");
    void playScriptedTurn("tool-toggle", {
      show: (next) => setView((now) => ({ ...now, ...next })),
      frame: (draw) => requestAnimationFrame(draw),
      // The reader's click on the call's line; the turn's closing drag is a click that opens nothing.
      act: (action) => {
        if (action === "toggle")
          document.querySelector<HTMLElement>(`[data-tool-id="${TOGGLE_CALL_ID}"][aria-expanded]`)?.click();
      },
    }).then(() => setState("settled"));
  };
  return (
    <div className="acpmux-shell" data-fold-look={look} style={{ height: "100%" }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header">
            <button type="button" className="ui-button" data-testid="tool-toggle-play" onClick={play}>
              Open and close a call while the reply streams
            </button>
            <output data-testid="tool-toggle-state" aria-live="polite">
              {state === "settled" ? "Turn settled" : state === "playing" ? "Playing" : "Ready"}
            </output>
          </header>
          <VirtualTranscript
            rows={turnView(view.rows, expanded, { working: view.working })}
            sessionId={`tool-toggle-motion-${look}`}
            working={view.working}
            sends={view.sends}
            dock={dock}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </div>
        <div ref={setDock} className="acpmux-dock">
          <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
            <div className="acpmux-composer-strip-placeholder" />
            <div className="acpmux-composer-box" style={{ height: view.card }} />
          </form>
        </div>
      </div>
    </div>
  );
}

/// Plays the turn and waits until its summary row is drawn and every motion rests.
const playTurn: Play = async (ctx) => {
  await ctx.click({ testId: "tool-toggle-play" });
  await ctx.waitFor(() => ctx.find({ testId: "tool-toggle-state" }).textContent === "Turn settled", {
    capMs: 10_000,
  });
  const thread = ctx.find({ selector: ".acpmux-thread" }) as HTMLElement;
  await ctx.waitFor(() => !thread.style.translate, { capMs: 2_000 });
};

const NOTE: Record<FoldLook, string> = {
  settle:
    "Shipped: one fold on the settle (180 ms); the line holds its pixel, the rows under ride its foot, and a close mid-open turns back over the travel left.",
  stack: "Before: a close mid-open plays a whole fold again from where it was drawn.",
  quick: "The fold on the quick step (80 ms).",
  jump: "The details open and close at once.",
};

export default componentEntry<{ look: FoldLook }>({
  id: "agent-pane.tool-toggle-motion",
  title: "Tool call toggle during a stream",
  area: "Agent pane",
  height: 600,
  anchors: [{ selector: "[data-testid=tool-toggle-play]" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The transcript's motion must not move the fixed play control." },
    settleMaxMs: { value: 10_000, reason: "The scripted turn streams for about three seconds, then settles." },
  },
  covers: [
    "agent-session/acpmux/conversation/fold.ts#useFold",
    "agent-session/acpmux/conversation/useAnchoredCollapse.ts#useAnchoredCollapse",
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
  ],
  load: async () => ToolToggleMotionGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../composerControls.css"),
      import("../bottomStack.css"),
    ]),
  variants: Object.fromEntries(
    (["settle", "stack", "quick", "jump"] as const).map((look) => [
      look,
      { props: { look }, play: playTurn, note: NOTE[look] },
    ]),
  ),
});
