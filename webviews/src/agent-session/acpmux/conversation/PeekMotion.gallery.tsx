// l10n-allow-file: deterministic visual fixtures for the inline media handoff gallery.
// This is a gallery-only prototype. It deliberately keeps the handoff to one fixed overlay so
// frame receipts can measure the motion before a production ReplyMedia owner takes it on.
import { useRef, useState, type TransitionEvent } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";

export type PeekMotionMode = "immediate" | "peek-open" | "anchored-peek-340" | "reduced-motion";

type Props = { mode: PeekMotionMode };

const OPEN_BUTTON = "Open inline preview";
const CLOSE_BUTTON = "Close inline preview";

function MediaArtwork() {
  return (
    <div className="peek-motion-art" aria-hidden="true">
      <div className="peek-motion-art__grid" />
      <div className="peek-motion-art__line" />
      <div className="peek-motion-art__cursor" />
      <span className="peek-motion-art__play">▶</span>
    </div>
  );
}

function PeekMotionGallery({ mode }: Props) {
  const [open, setOpen] = useState(false);
  const [settled, setSettled] = useState<"closed" | "opening" | "open" | "closing">("closed");
  const [generation, setGeneration] = useState(0);
  const [closeRect, setCloseRect] = useState("not closed");
  const [lateCompletion, setLateCompletion] = useState(false);
  const sourceRef = useRef<HTMLElement>(null);
  const generationRef = useRef(0);
  const changeOpen = (next: boolean) => {
    generationRef.current += 1;
    setGeneration(generationRef.current);
    if (!next) {
      const rect = sourceRef.current?.getBoundingClientRect();
      setCloseRect(
        rect
          ? `${Math.round(rect.x)},${Math.round(rect.y)} ${Math.round(rect.width)}x${Math.round(rect.height)}`
          : "fallback",
      );
    }
    setLateCompletion(false);
    setOpen(next);
    setSettled(
      mode === "immediate" || mode === "reduced-motion"
        ? next
          ? "open"
          : "closed"
        : next
          ? "opening"
          : "closing",
    );
  };
  const settleTransition = (event: TransitionEvent<HTMLDivElement>) => {
    if (event.target !== event.currentTarget || event.propertyName !== "transform") return;
    if (generationRef.current !== generation) {
      setLateCompletion(true);
      return;
    }
    if ((open && settled !== "opening") || (!open && settled !== "closing")) {
      setLateCompletion(true);
      return;
    }
    setSettled(open ? "open" : "closed");
  };
  return (
    <section
      className="peek-motion-gallery"
      data-peek-mode={mode}
      data-peek-open={open}
      data-peek-settled={settled}
    >
      <div className="peek-motion-gallery__eyebrow">Agent reply · visual media</div>
      <article ref={sourceRef} className="peek-motion-source" data-peek-source>
        <div className="peek-motion-source__copy">
          <div className="peek-motion-source__label">Build review</div>
          <h2>Checkout flow recording</h2>
          <p>Watch the request move from the composer to the result pane.</p>
          <div className="peek-motion-source__meta">
            <span>MP4</span>
            <span>00:42</span>
            <span>720p</span>
          </div>
        </div>
        <button
          className="peek-motion-thumbnail"
          type="button"
          aria-label={OPEN_BUTTON}
          onClick={() => changeOpen(true)}
        >
          <MediaArtwork />
          <span className="peek-motion-thumbnail__caption">Open preview</span>
        </button>
      </article>

      <div className="peek-motion-composer" aria-label="Composer preview">
        <span>Ask a follow-up about this recording…</span>
        <span className="peek-motion-composer__key">⌘ ↵</span>
      </div>

      <output
        className="peek-motion-receipt"
        data-testid="peek-receipt"
        data-peek-receipt
        aria-live="polite"
      >
        generation {generation} · close rect {closeRect} ·{" "}
        {lateCompletion ? "late completion" : "no late completion"}
      </output>

      <div className="peek-motion-layer" data-peek-overlay aria-hidden={!open}>
        <button
          className="peek-motion-backdrop"
          type="button"
          aria-label={CLOSE_BUTTON}
          tabIndex={open ? 0 : -1}
          onClick={() => changeOpen(false)}
        />
        <div
          className="peek-motion-dialog"
          role="dialog"
          aria-modal="true"
          aria-label="Checkout flow recording"
          tabIndex={-1}
          onTransitionEnd={settleTransition}
        >
          <div className="peek-motion-dialog__bar">
            <span>Checkout flow recording</span>
            <button
              type="button"
              aria-label={CLOSE_BUTTON}
              tabIndex={open ? 0 : -1}
              onClick={() => changeOpen(false)}
            >
              Close
            </button>
          </div>
          <MediaArtwork />
          <div className="peek-motion-dialog__footer">
            <span>MP4 · 00:42 · 720p</span>
            <span className="peek-motion-dialog__status">Preview ready</span>
          </div>
        </div>
      </div>
    </section>
  );
}

const playOpenClose: Play = async (ctx) => {
  const mode = ctx.document.querySelector<HTMLElement>("[data-peek-mode]")?.dataset.peekMode;
  const probe = mode !== "immediate" && mode !== "reduced-motion";
  if (probe)
    ctx.motion.start({
      kind: "reasoning-slider",
      target: "[data-peek-overlay]",
      visual: ".peek-motion-dialog",
      viewport: ".peek-motion-gallery",
      maxMs: 500,
    });
  await ctx.click({ role: "button", name: OPEN_BUTTON });
  await ctx.waitFor(() => ctx.document.querySelector('[data-peek-settled="open"]'));
  if (probe) {
    const report = ctx.motion.stop();
    if (!report || report.status === "fail")
      throw new Error(report?.problems.join("; ") ?? "Peek motion was not sampled");
  }
  await ctx.click({ role: "button", name: CLOSE_BUTTON });
  await ctx.waitFor(() => ctx.document.querySelector('[data-peek-settled="closed"]'));
  const receipt = ctx.find({ testId: "peek-receipt" }).textContent ?? "";
  if (
    !/generation \d+/.test(receipt) ||
    !receipt.includes("no late completion") ||
    !/close rect (fallback|\d)/.test(receipt)
  )
    throw new Error(`Peek receipt was incomplete: ${receipt}`);
};

export default componentEntry<Props>({
  id: "agent-pane.peek-motion",
  title: "Anchored inline media Peek",
  area: "Agent pane",
  height: 540,
  widths: { narrow: 420, normal: 720, wide: 960 },
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/ImageViewer.tsx#ImageViewer",
    "agent-session/acpmux/chips/ReplyMedia.tsx#VideoThumbnail",
  ],
  load: async () => PeekMotionGallery,
  styles: () => import("./PeekMotion.gallery.css"),
  anchors: [{ selector: "[data-peek-source]" }, { selector: ".peek-motion-composer" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "The fixed single-overlay handoff must not move the source card or composer.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Opening media is a composited overlay; no layout reflow is allowed.",
    },
    settleMaxMs: {
      value: 420,
      reason:
        "The longest prototype open path is 340 ms and must settle before the late-completion receipt.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Peek is transform and opacity only; a long compositor frame is a prototype failure.",
    },
  },
  variants: {
    immediate: {
      note: "No transition: establishes the immediate handoff baseline.",
      props: { mode: "immediate" },
      play: playOpenClose,
      checks: {
        settleMaxMs: { value: 100, reason: "The immediate baseline has no transition budget." },
      },
    },
    "peek-open": {
      note: "A compact 180 ms open and 180 ms close for routine inline media.",
      props: { mode: "peek-open" },
      play: playOpenClose,
      checks: {
        settleMaxMs: {
          value: 240,
          reason: "The 180 ms handoff leaves a small frame-settle margin.",
        },
      },
    },
    "anchored-peek-340": {
      note: "A more legible source handoff: 340 ms in, 260 ms out, with the source card fixed underneath.",
      props: { mode: "anchored-peek-340" },
      play: playOpenClose,
    },
    "reduced-motion": {
      note: "Policy-safe mode: the overlay settles immediately and keeps the same single layer.",
      props: { mode: "reduced-motion" },
      play: playOpenClose,
      checks: {
        settleMaxMs: {
          value: 100,
          reason: "Reduced-motion mode must settle without a transition.",
        },
      },
    },
  },
});
