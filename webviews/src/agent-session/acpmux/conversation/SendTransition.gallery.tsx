// l10n-allow-file: deterministic send-transition fixture labels.
// Sending a prompt is one state transition in each starting state (leo-workspace design/motion.md
// "Send states"): a chat whose rows fit (the new rows appear where they rest and nothing above
// moves), a full chat at its latest row (the rows above rise into place on the follow glide instead
// of in one frame) and a full chat scrolled up (the view glides to the send as Jump to latest does).
// The Send button does what the real send does in one React update: it counts the send (`sends`)
// and appends the prompt's row and the running turn's live line (turnView `working`, `lineBelow`).
// The `late` variants land those rows a frame after the send was counted, as a prompt's row can a
// commit or two after the composer cleared. send-transition-transcript.test.ts samples the frames.
import { useMemo, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";

type Scene = {
  /// Finished turns before the send.
  turns: number;
  /// Whether the prompt's row and the live line land a frame after the send is counted.
  late?: boolean;
  /// The glide turned off (`data-follow-glide="off"`, followGlide.ts): the view before it.
  glideOff?: boolean;
};

const paragraph = (index: number) =>
  `Answer ${index}: the lighthouse keeper checked the glass, crossed the gallery, and watched the tide ` +
  "return beneath the window while the lamp turned over the harbour.";

function SendTransitionGallery({ turns, late = false, glideOff = false }: Scene) {
  const [sends, setSends] = useState(0);
  const [sent, setSent] = useState(false);
  const rows = useMemo(() => {
    const history: AcpmuxRow[] = Array.from({ length: turns }, (_, index) => [
      { id: `send-user-${index}`, kind: "user", version: 1, at: index * 2 + 1, text: `Prompt ${index + 1}` },
      { id: `send-answer-${index}`, kind: "assistant", version: 1, at: index * 2 + 2, text: paragraph(index + 1) },
    ]).flat() as AcpmuxRow[];
    const prompt: AcpmuxRow[] = sent
      ? [{ id: "send-new-prompt", kind: "user", version: 1, at: turns * 2 + 1, text: "Check the lamp once more" }]
      : [];
    return turnView([...history, ...prompt], new Set(), { working: sent, lineBelow: true, liveRuns: true });
  }, [turns, sent]);
  const send = () => {
    if (sent) return;
    if (late) {
      setSends((count) => count + 1);
      requestAnimationFrame(() => setSent(true));
      return;
    }
    // One update, as the real send: the count and the rows commit together.
    setSends((count) => count + 1);
    setSent(true);
  };
  return (
    <div
      className="acpmux-shell send-transition-gallery"
      data-follow-glide={glideOff ? "off" : undefined}
      style={{ height: "100%" }}
    >
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header">
            <button type="button" className="ui-button" data-testid="send-transition-send" onClick={send}>
              Send
            </button>
            <output data-testid="send-transition-state" aria-live="polite">
              {sent ? "Sent" : "Ready"}
            </output>
          </header>
          <VirtualTranscript
            rows={rows}
            sessionId="send-transition"
            onToggleActivity={() => {}}
            expanded={new Set()}
            working={sent}
            sends={sends}
          />
        </div>
      </div>
    </div>
  );
}

const scroller = (ctx: Parameters<Play>[0]) => ctx.find({ selector: ".acpmux-scroll" }) as HTMLElement;

/// The view at the latest row, ready to send.
const atBottom: Play = async (ctx) => {
  const node = scroller(ctx);
  await ctx.waitFor(() => node.querySelector(".acpmux-row"), { capMs: 10_000 });
};

/// The reader scrolled up about three viewports (a wheel up, so the view lets go of the latest row).
const parked: Play = async (ctx) => {
  await atBottom(ctx);
  const node = scroller(ctx);
  await ctx.waitFor(() => node.scrollHeight > node.clientHeight * 4, { capMs: 10_000 });
  node.dispatchEvent(new WheelEvent("wheel", { deltaY: -120, bubbles: true }));
  await ctx.scroll({ selector: ".acpmux-scroll" }, Math.max(0, node.scrollHeight - node.clientHeight * 4));
};

const FULL = 12;

export default componentEntry<Scene>({
  id: "agent-pane.send-transition",
  title: "Send transition",
  area: "Agent pane",
  height: 560,
  anchors: [{ selector: "[data-testid=send-transition-send]" }],
  checks: {
    anchorMovePx: { value: 0, reason: "A send must not move the fixed Send control." },
  },
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript"],
  load: async () => SendTransitionGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../composerControls.css"),
      import("./streamingFollowMotion.css"),
    ]),
  variants: {
    "partly-full": {
      note: "Two short turns that fit: Send puts the prompt's row and the live line where they rest; nothing above moves.",
      props: { turns: 2 },
      play: atBottom,
    },
    "full-at-bottom": {
      note: "A full chat at its latest row: Send lets the rows above rise into place on the follow glide.",
      props: { turns: FULL },
      play: atBottom,
    },
    "full-at-bottom-late": {
      note: "As full-at-bottom, with the prompt's row landing a frame after the send: still one rise.",
      props: { turns: FULL, late: true },
      play: atBottom,
    },
    "full-parked": {
      note: "A full chat scrolled up three viewports: Send glides the view to the latest row.",
      props: { turns: FULL },
      play: parked,
    },
    "full-parked-late": {
      note: "As full-parked, with the prompt's row landing a frame after the send: one glide, no second step.",
      props: { turns: FULL, late: true },
      play: parked,
    },
    "before-full-at-bottom": {
      note: "Before: the follow glide off, so a send at the latest row moves the rows up in one frame.",
      props: { turns: FULL, glideOff: true },
      play: atBottom,
    },
  },
});
