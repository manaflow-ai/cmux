// l10n-allow-file: gallery labels and content are deterministic fixture text.
import { useState } from "react";
import type { Play } from "../gallery/play";
import { componentEntry } from "../gallery/format";
import { ScrollArea } from "./ScrollArea";

type Props = { initial?: "long" | "short" };

function ScrollAreaMotionGallery({ initial = "long" }: Props) {
  const [long, setLong] = useState(initial === "long");
  const count = long ? 18 : 5;
  return (
    <div className="scroll-area-motion-gallery">
      <div className="scroll-area-motion-gallery__controls">
        <button type="button" className="ui-button" onClick={() => setLong(false)} data-testid="scroll-thumb-shrink">
          Shrink content
        </button>
        <button type="button" className="ui-button" onClick={() => setLong(true)} data-testid="scroll-thumb-grow">
          Grow content
        </button>
      </div>
      <ScrollArea
        className="scroll-area-motion-gallery__scroll"
        viewportClassName="scroll-area-motion-gallery__viewport"
      >
        {Array.from({ length: count }, (_, index) => (
          <div key={index} className="scroll-area-motion-gallery__item">
            Transcript line {index + 1}
          </div>
        ))}
      </ScrollArea>
    </div>
  );
}

const thumbResize: Play = async (ctx) => {
  const thumb = () => ctx.find({ selector: ".scroll-area-motion-gallery__scroll .cmux-scrollbar-thumb" });
  await ctx.waitFor(() => thumb().getBoundingClientRect().height > 0);
  const before = thumb().getBoundingClientRect().height;
  ctx.motion.start({
    kind: "scroll-thumb",
    target: ".scroll-area-motion-gallery__scroll",
    visual: ".scroll-area-motion-gallery__scroll .cmux-scrollbar-thumb",
    maxMs: 3000,
  });
  await ctx.click({ testId: "scroll-thumb-shrink" });
  await ctx.waitFor(() => thumb().getBoundingClientRect().height > before + 1);
  const shrunk = thumb().getBoundingClientRect().height;
  await ctx.click({ testId: "scroll-thumb-grow" });
  await ctx.waitFor(() => thumb().getBoundingClientRect().height < shrunk - 1);
  // Judge the motion once the thumb's size transition has finished and held for a few frames (the
  // probe calls it settled after three samples at the final size), not mid-way.
  await ctx.waitFor(() => thumb().getAnimations().length === 0);
  for (let frame = 0; frame < 3; frame++) await new Promise((done) => requestAnimationFrame(done));
  const report = ctx.motion.stop();
  if (!report || report.status === "fail")
    throw new Error(report?.problems.join("; ") ?? "scroll thumb motion was not sampled");
};

export default componentEntry<Props>({
  id: "ui.scroll-area-motion",
  title: "Scroll area motion",
  area: "UI primitives",
  height: 260,
  anchors: [{ selector: ".scroll-area-motion-gallery__controls" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Changing content must not move the controls." },
    settleMaxMs: { value: 500, reason: "Thumb resizing is a local transition." },
  },
  covers: ["ui/ScrollArea.tsx#ScrollArea"],
  load: async () => ScrollAreaMotionGallery,
  styles: () => Promise.all([import("./ui.css"), import("./ScrollArea.gallery.css")]),
  variants: {
    long: { props: {} },
    "thumb-resize": { props: {}, play: thumbResize },
    short: { props: { initial: "short" } },
  },
});
