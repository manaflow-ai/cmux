// l10n-allow-file: deterministic motion fixture labels.
import { useEffect, useMemo, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";

const paragraph = (index: number) =>
  `Streaming paragraph ${index}: the lighthouse keeper checked the glass, crossed the gallery, and watched the tide return beneath the window.`;

/// `eased-follow` is the app's: the followed view's steps ease on the compositor (followGlide.ts).
/// `steady-reveal` is the view before it, which took each new line in one frame. The other two are
/// alternatives kept for comparison.
type MotionVariant = "eased-follow" | "steady-reveal" | "smooth-follow" | "subtle-fade";

function StreamingFollowMotionGallery({ variant }: { variant: MotionVariant }) {
  const [count, setCount] = useState(0);
  const [streaming, setStreaming] = useState(false);
  const [done, setDone] = useState(false);
  const timer = useRef<number | undefined>(undefined);
  useEffect(
    () => () => {
      if (timer.current !== undefined) window.clearInterval(timer.current);
    },
    [],
  );
  const rows = useMemo(() => {
    const history: AcpmuxRow[] = Array.from({ length: 12 }, (_, index) => [
      { id: `history-user-${index}`, kind: "user", version: 1, at: index + 1, text: `Prompt ${index + 1}` },
      { id: `history-answer-${index}`, kind: "assistant", version: 1, at: index + 1, text: paragraph(index) },
    ]).flat();
    const text = Array.from({ length: count }, (_, index) => paragraph(index + 12)).join("\n\n");
    // With the running turn's line under the reply, as the app draws it (Debug `liveLineBelow`).
    return turnView(
      [...history, { id: "streaming-answer", kind: "assistant", version: count + 1, at: 99, text, streaming }],
      new Set(),
      { working: streaming, lineBelow: true, liveRuns: true },
    );
  }, [count, streaming]);
  const start = () => {
    if (timer.current !== undefined) window.clearInterval(timer.current);
    setDone(false);
    setStreaming(true);
    setCount(0);
    let next = 0;
    timer.current = window.setInterval(() => {
      next += 1;
      setCount(next);
      if (next >= 28) {
        window.clearInterval(timer.current);
        timer.current = undefined;
        setStreaming(false);
        setDone(true);
      }
    }, 45);
  };
  return (
    <div
      className={`acpmux-shell streaming-follow-motion-gallery streaming-follow-motion-gallery--${variant}`}
      data-follow-glide={variant === "eased-follow" ? undefined : "off"}
      style={{ height: "100%" }}
    >
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header">
            <button type="button" className="ui-button" data-testid="stream-follow-start" onClick={start}>
              Start deterministic stream
            </button>
            <output data-testid="stream-follow-done" aria-live="polite">
              {done ? "Stream settled" : "Ready"}
            </output>
          </header>
          <VirtualTranscript
            rows={rows}
            sessionId="stream-motion"
            onToggleActivity={() => {}}
            expanded={new Set()}
            working={streaming}
          />
        </div>
      </div>
    </div>
  );
}

const streamFollow: Play = async (ctx) => {
  const scroller = ctx.find({ selector: ".acpmux-scroll" }) as HTMLElement;
  if (scroller.clientHeight < 100) throw new Error("The comparison transcript must have a visible viewport");
  ctx.motion.start({ kind: "streaming-follow", target: ".acpmux-scroll", maxMs: 3_000 });
  await ctx.click({ testId: "stream-follow-start" });
  await ctx.waitFor(() => ctx.find({ testId: "stream-follow-done" }).textContent === "Stream settled", {
    capMs: 4_000,
  });
  const report = ctx.motion.stop();
  if (!report || report.status === "fail")
    throw new Error(report?.problems.join("; ") ?? "streaming follow was not sampled");
};

/// The reader is deliberately away from the latest message while the same
/// deterministic stream grows. A layout-only scroll adjustment must not move
/// the thumb or pull the reader back to the bottom.
const streamWhileScrolledUp: Play = async (ctx) => {
  await ctx.click({ testId: "stream-follow-start" });
  const scroller = ctx.find({ selector: ".acpmux-scroll" }) as HTMLElement;
  await ctx.waitFor(() => scroller.scrollHeight > scroller.clientHeight, { capMs: 3_000 });
  await ctx.scroll({ selector: ".acpmux-scroll" }, 180);
  const held = scroller.scrollTop;
  await ctx.waitFor(() => ctx.find({ testId: "stream-follow-done" }).textContent === "Stream settled", {
    capMs: 4_000,
  });
  const moved = Math.abs(scroller.scrollTop - held);
  if (moved > 1) throw new Error(`Scrolled-up transcript moved ${moved.toFixed(2)}px while streaming`);
};

export default componentEntry<{ variant: MotionVariant }>({
  id: "agent-pane.streaming-follow-motion",
  title: "Streaming follow motion",
  area: "Agent pane",
  height: 560,
  anchors: [{ selector: "[data-testid=stream-follow-start]" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Streaming content must not move the fixed stream control." },
    settleMaxMs: { value: 4_000, reason: "The deterministic stream has a fixed 1.3 second duration." },
  },
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript"],
  load: async () => StreamingFollowMotionGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../composerControls.css"),
      import("./streamingFollowMotion.css"),
    ]),
  variants: {
    "eased-follow": { props: { variant: "eased-follow" }, play: streamFollow },
    "steady-reveal": { props: { variant: "steady-reveal" }, play: streamFollow },
    "smooth-follow": { props: { variant: "smooth-follow" }, play: streamFollow },
    "subtle-fade": { props: { variant: "subtle-fade" }, play: streamFollow },
    "stream-scrolled-up": { props: { variant: "eased-follow" }, play: streamWhileScrolledUp },
  },
});
