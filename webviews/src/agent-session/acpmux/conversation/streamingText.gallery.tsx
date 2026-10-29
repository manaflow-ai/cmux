// l10n-allow-file: deterministic streaming fixture labels.
// A long reply streaming into the transcript over a chat's history, with the docked composer's
// room at its foot: the reply of the frame-budget test (test/streaming-text-frames.test.ts), at
// Claude's cadence or Codex's. It grows a word at a time; headings, lists, the code card and the
// table form without moving what is above them; its last line keeps clear of the composer while
// the view follows. The play records it streaming end to end (run the matrix with --record-video).
import { useEffect, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import { history, REPLY, schedule, type Cadence } from "./streamingTextFixture";
import { turnView } from "./turns";

const PROMPT: AcpmuxRow = {
  id: "live-user",
  version: 1,
  at: 100_000,
  kind: "user",
  text: "Why does the relay fall over?",
};
const expanded = new Set<string>();

function StreamingTextGallery({ cadence }: { cadence: Cadence }) {
  const [rows, setRows] = useState<AcpmuxRow[]>(() => [...history(), PROMPT]);
  const [phase, setPhase] = useState<"ready" | "streaming" | "done">("ready");
  const [dock, setDock] = useState<HTMLElement | null>(null);
  const timers = useRef<number[]>([]);
  useEffect(() => () => timers.current.forEach((timer) => window.clearTimeout(timer)), []);
  const start = () => {
    timers.current.forEach((timer) => window.clearTimeout(timer));
    timers.current = [];
    setPhase("streaming");
    let text = "";
    let version = 0;
    let frame = 0;
    // As direct.ts: deltas land as they arrive; one snapshot draws per display frame.
    const draw = (streaming: boolean) => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() =>
        setRows([
          ...history(),
          PROMPT,
          { id: "live-answer", version, at: 100_001, kind: "assistant", text, streaming },
          ...(streaming
            ? []
            : [{ id: "live-end", version: 1, at: 120_000, kind: "turnSummary", status: "completed" } as AcpmuxRow]),
        ]),
      );
    };
    const deltas = schedule(REPLY, cadence);
    deltas.forEach((delta, index) =>
      timers.current.push(
        window.setTimeout(() => {
          text += delta.text;
          version += 1;
          const last = index === deltas.length - 1;
          draw(!last);
          if (last) setPhase("done");
        }, delta.at),
      ),
    );
  };
  const working = phase === "streaming";
  return (
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header">
            <button type="button" className="ui-button" data-testid="stream-text-start" onClick={start}>
              Stream the reply
            </button>
            <output data-testid="stream-text-done" aria-live="polite">
              {phase === "done" ? "Stream settled" : phase === "streaming" ? "Streaming" : "Ready"}
            </output>
          </header>
          <VirtualTranscript
            rows={turnView(rows, expanded, { working })}
            sessionId={`stream-text-${cadence}`}
            working={working}
            jumpButton
            dock={dock}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </div>
        <div ref={setDock} className="acpmux-dock">
          {/* The docked composer after the first send: the strip's held height over a one-line card. */}
          <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
            <div className="acpmux-composer-strip-placeholder" />
            <div className="acpmux-composer-box" style={{ height: 88 }} />
          </form>
        </div>
      </div>
    </div>
  );
}

const streamReply: Play = async (ctx) => {
  ctx.motion.start({ kind: "streaming-follow", target: ".acpmux-scroll", maxMs: 30_000 });
  await ctx.click({ testId: "stream-text-start" });
  await ctx.waitFor(() => ctx.find({ testId: "stream-text-done" }).textContent === "Stream settled", {
    capMs: 30_000,
  });
  // The reveal drains what is left after the last delta (StreamReveal.finishMs).
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-row[data-row-id=live-answer] .cv-fresh"), {
    capMs: 2_000,
  });
  const report = ctx.motion.stop();
  if (!report || report.status === "fail")
    throw new Error(report?.problems.join("; ") ?? "the streaming reply was not sampled");
};

const jumpDuringStream: Play = async (ctx) => {
  await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
  await ctx.click({ testId: "stream-text-start" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-latest[data-shown]"));
  await ctx.click({ selector: ".acpmux-jump-latest" });
  await ctx.waitFor(() => ctx.find({ testId: "stream-text-done" }).textContent === "Stream settled", { capMs: 30_000 });
  await ctx.waitFor(() => {
    const node = ctx.find({ selector: ".acpmux-scroll" }) as HTMLElement;
    return node.scrollHeight - node.clientHeight - node.scrollTop <= 4;
  });
};

export default componentEntry<{ cadence: Cadence }>({
  id: "agent-pane.streaming-text",
  title: "Streaming text",
  area: "Agent pane",
  height: 640,
  anchors: [{ selector: "[data-testid=stream-text-start]" }],
  checks: {
    anchorMovePx: { value: 0, reason: "A streaming reply must not move the header above the transcript." },
    settleMaxMs: { value: 30_000, reason: "The fixture reply streams for about 14 seconds at Claude's cadence." },
    longFrameFailMs: {
      value: 50,
      reason: "The reply's code fence closes once; its first Shiki highlight compiles the grammar.",
    },
  },
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript", "agent-session/acpmux/conversation/RevealedMarkdown.tsx"],
  load: async () => StreamingTextGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../composerControls.css"),
      import("../bottomStack.css"),
    ]),
  variants: {
    claude: { props: { cadence: "claude" }, play: streamReply },
    codex: { props: { cadence: "codex" }, play: streamReply },
    "jump-during-stream": { props: { cadence: "codex" }, play: jumpDuringStream },
  },
});
