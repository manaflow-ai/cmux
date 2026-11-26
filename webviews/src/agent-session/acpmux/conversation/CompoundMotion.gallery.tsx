// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The compound motions, before and after (Leo, 2026-11-22: "when i send it collapses the compser then
// sends it to you... but i think we should be able to calculate it out to be like one smooth motion.
// there are a lot of these possible compound movement situations, esp with folds, that i think we can
// watch for and map out harder to have more cohesive animations").
// Each case (compoundScenarios.tsx) plays in the real transcript twice: `after` on the thread's one
// motion (motionTransaction.ts: every move in a frame joins one plan, one start, one curve, one end),
// `before` with each mover on its own. Press Play; the map's numbers come from
// webviews/test/compound-motion.test.ts on the same cases.
import { useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { COMPOUND_CASES, type CompoundCase } from "./compoundCases";
import { CompoundPane, playCompound, type PaneState } from "./compoundScenarios";
import { COMPOUND_MOTION_ATTR } from "./motionTransaction";

type Props = { which: CompoundCase; arm: "transaction" | "separate" };

const NOTES: Record<CompoundCase, string> = {
  control: "Nothing happens: nothing moves.",
  "send-1": "A one-line send: the composer clears and the prompt's row lands.",
  "send-5": "A five-line send: the composer collapses four lines and the prompt's row lands 30 ms later.",
  "send-15": "A fifteen-line send: the tallest collapse, then the prompt's row.",
  "send-5-one-commit":
    "A five-line send whose prompt's row comes in the send's own commit (a loaded host): one motion all the same.",
  "queue-scrolled":
    "A five-line send while the agent works, scrolled up: the chat goes to its latest row and the prompt queues over the composer.",
  steer: "A prompt sent while a call runs (a steer): the composer clears over the streaming reply.",
  "fold-stream": "The reader opens a call's output while the reply streams under it.",
  "resize-fold": "The split narrows in the frame the reader opens a call's output.",
  "growth-stream": "The prompt field grows two lines while the reply streams.",
  "stack-stream": "A queue card comes into the stack while the reply streams.",
  "subagent-land": "A subagent's block reports and takes its place.",
  "recap-end": "The turn ends: its work folds and the recap comes in (held by #49624's fold variants).",
};

function CompoundMotionGallery({ which, arm }: Props) {
  const show = useRef<(next: Partial<PaneState>) => void>(() => {});
  const host = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<"ready" | "playing" | "settled">("ready");
  const play = () => {
    if (state === "playing" || !host.current) return;
    setState("playing");
    void playCompound(which, {
      show: (next) => show.current(next),
      frame: (draw) => requestAnimationFrame(draw),
      step: () => {},
      root: host.current,
    }).then(() => setState("settled"));
  };
  return (
    <div
      ref={host}
      style={{ height: "100%", display: "flex", flexDirection: "column" }}
      {...{ [COMPOUND_MOTION_ATTR]: arm }}
    >
      <div className="acpmux-header">
        <button type="button" className="ui-button" data-testid="compound-play" onClick={play}>
          Play
        </button>
        <output data-testid="compound-state" aria-live="polite">
          {state === "settled" ? "Settled" : state === "playing" ? "Playing" : "Ready"}
        </output>
      </div>
      <CompoundPane sessionId={`compound-${which}-${arm}`} bind={(set) => (show.current = set)} />
    </div>
  );
}

const playCase: Play = async (ctx) => {
  await ctx.click({ testId: "compound-play" });
  await ctx.waitFor(() => ctx.find({ testId: "compound-state" }).textContent === "Settled", { capMs: 15_000 });
};

const variants: Record<string, { props: Props; play: Play; note: string }> = {};
for (const which of COMPOUND_CASES) {
  variants[`${which}-after`] = { props: { which, arm: "transaction" }, play: playCase, note: `After: ${NOTES[which]}` };
  variants[`${which}-before`] = { props: { which, arm: "separate" }, play: playCase, note: `Before: ${NOTES[which]}` };
}

export default componentEntry<Props>({
  id: "agent-pane.compound-motion",
  title: "Compound motion: send collapse, folds, growth, stack, before and after",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/conversation/motionTransaction.ts#threadTransaction",
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
  ],
  load: async () => CompoundMotionGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../composerControls.css"),
      import("../composerStates.css"),
      import("../bottomStack.css"),
      import("../markdownField.css"),
    ]),
  variants,
});
