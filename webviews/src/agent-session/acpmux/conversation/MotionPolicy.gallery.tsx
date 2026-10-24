// l10n-allow-file: deterministic visual fixtures for the live motion policy gallery.
// This gallery owns one page-scoped reveal loop so the policy toggle can record a settlement frame
// without walking rows, tokens or document animations. It is a prototype, not production.
import { useEffect, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";

export type MotionPolicyMode = "flush-on-policy" | "content-pacing-exempt";

type Props = { mode: MotionPolicyMode };

const TEXT =
  "The reply keeps arriving while the agent checks the request path and prepares the next step.";
const START = "Start reveal";
const POLICY = "Turn Calm Mode on";

function MotionPolicyGallery({ mode }: Props) {
  const [streaming, setStreaming] = useState(false);
  const [calm, setCalm] = useState(false);
  const [visible, setVisible] = useState(0);
  const [frames, setFrames] = useState(0);
  const [settledFrame, setSettledFrame] = useState<number | null>(null);
  const frame = useRef<number | undefined>(undefined);
  const latest = useRef({ visible, frames, calm, streaming });
  latest.current = { visible, frames, calm, streaming };

  useEffect(() => {
    if (!streaming) return;
    const tick = () => {
      frame.current = undefined;
      const state = latest.current;
      const nextFrames = state.frames + 1;
      const nextVisible = Math.min(TEXT.length, state.visible + (state.calm ? 4 : 2));
      setFrames(nextFrames);
      setVisible(nextVisible);
      if (nextVisible === TEXT.length) {
        setStreaming(false);
        setSettledFrame(nextFrames);
      } else frame.current = requestAnimationFrame(tick);
    };
    frame.current = requestAnimationFrame(tick);
    return () => {
      if (frame.current !== undefined) cancelAnimationFrame(frame.current);
      frame.current = undefined;
    };
  }, [streaming]);

  const start = () => {
    if (frame.current !== undefined) cancelAnimationFrame(frame.current);
    setCalm(false);
    setVisible(0);
    setFrames(0);
    setSettledFrame(null);
    setStreaming(true);
  };

  const changePolicy = () => {
    setCalm(true);
    if (mode === "flush-on-policy") {
      if (frame.current !== undefined) cancelAnimationFrame(frame.current);
      frame.current = undefined;
      const settlementFrame = latest.current.frames + 1;
      setFrames(settlementFrame);
      setVisible(TEXT.length);
      setStreaming(false);
      setSettledFrame(settlementFrame);
    }
  };

  const stateLabel =
    settledFrame === null
      ? streaming
        ? "Revealing"
        : "Ready"
      : `Settled on frame ${settledFrame}`;
  return (
    <section
      className="motion-policy-gallery"
      data-policy-mode={mode}
      data-policy-streaming={streaming}
      data-policy-settled={settledFrame !== null}
    >
      <header className="motion-policy-gallery__header">
        <div>
          <div className="motion-policy-gallery__eyebrow">Agent reply · live policy</div>
          <h2>One page loop, one settlement</h2>
          <p>
            Toggle the host motion policy while a reply is revealing. The receipt names the frame
            where it settled.
          </p>
        </div>
        <output data-testid="policy-state" aria-live="polite">
          {stateLabel}
        </output>
      </header>

      <div className="motion-policy-gallery__card">
        <div className="motion-policy-gallery__bar">
          <span className={streaming ? "is-live" : ""}>{streaming ? "Streaming" : "Reply"}</span>
          <span data-testid="policy-frame">Frame {frames}</span>
        </div>
        <p className="motion-policy-gallery__reply">
          {TEXT.slice(0, visible)}
          {streaming && <span className="motion-policy-gallery__caret" aria-hidden="true" />}
        </p>
        <div className="motion-policy-gallery__progress" aria-hidden="true">
          <span style={{ transform: `scaleX(${visible / TEXT.length})` }} />
        </div>
      </div>

      <div className="motion-policy-gallery__controls">
        <button type="button" className="ui-button" data-testid="policy-start" onClick={start}>
          {START}
        </button>
        <button
          type="button"
          className="ui-button ui-button--quiet"
          data-testid="policy-toggle"
          disabled={!streaming}
          onClick={changePolicy}
        >
          {POLICY}
        </button>
      </div>
      <p className="motion-policy-gallery__receipt" data-testid="policy-receipt">
        {settledFrame === null
          ? "No settlement receipt yet."
          : `Policy settled once on frame ${settledFrame}; no late completion.`}
      </p>
    </section>
  );
}

const policyPlay: Play = async (ctx) => {
  await ctx.click({ testId: "policy-start" });
  await ctx.waitFor(() => ctx.find({ testId: "policy-state" }).textContent === "Revealing");
  await ctx.click({ testId: "policy-toggle" });
  await ctx.waitFor(() =>
    Boolean(
      ctx.document
        .querySelector('[data-testid="policy-receipt"]')
        ?.textContent?.includes("settled once"),
    ),
  );
  const frameText = ctx.find({ testId: "policy-frame" }).textContent ?? "";
  if (!/Frame \d+/.test(frameText)) throw new Error("policy frame receipt was missing");
};

export default componentEntry<Props>({
  id: "agent-pane.motion-policy",
  title: "Live motion policy settlement",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 420, normal: 720, wide: 960 },
  pane: true,
  covers: ["agent-session/acpmux/conversation/RevealedMarkdown.tsx#RevealedMarkdown"],
  load: async () => MotionPolicyGallery,
  styles: () => import("./MotionPolicy.gallery.css"),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Changing the page motion policy must not move the policy controls.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "The reveal changes one composited progress bar and text content in place.",
    },
    settleMaxMs: {
      value: 250,
      reason: "The policy event must settle in one page-scoped update before a late completion.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "The policy bridge owns one rAF loop and must not introduce long frames.",
    },
  },
  anchors: [
    { selector: ".motion-policy-gallery__controls" },
    { selector: ".motion-policy-gallery__header" },
  ],
  variants: {
    "flush-on-policy": {
      note: "Calm Mode flushes the pending JavaScript reveal and cancels its one rAF loop on the next policy event.",
      props: { mode: "flush-on-policy" },
      play: policyPlay,
    },
    "content-pacing-exempt": {
      note: "Calm Mode leaves content pacing as an explicit exemption; the same page loop settles once when the text finishes.",
      props: { mode: "content-pacing-exempt" },
      play: policyPlay,
      checks: {
        settleMaxMs: {
          value: 600,
          reason:
            "The explicit content pacing exemption drains the deterministic 25-frame fixture before settling.",
        },
      },
    },
  },
});
