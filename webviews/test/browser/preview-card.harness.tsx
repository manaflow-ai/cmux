// The rail's preview card (threadMinimap/PreviewCard.tsx) on its own, drawn as the rails draw it: in
// the transcript scroller's parent (the layer), counted from an anchor at the rail's origin. A test
// renders it with `window.__card(props)`, the same component instance each time, and reads where it
// sits against where it should (`window.__expected()`, model.ts cardOffset).
import { createRoot } from "react-dom/client";
import { PreviewCard } from "../../src/agent-session/acpmux/threadMinimap/PreviewCard";
import { cardOffset, replyPreview } from "../../src/agent-session/acpmux/threadMinimap/model";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";

const VIEWPORT = 600;
const root = document.getElementById("root")!;
document.body.style.margin = "0";
// The layer (the scroller's parent), the scroller in it, and the rail's origin in the scroller.
const layer = document.createElement("div");
Object.assign(layer.style, { position: "relative", width: "1000px", height: `${VIEWPORT}px`, overflow: "hidden" });
const scroller = document.createElement("div");
Object.assign(scroller.style, { position: "absolute", inset: "0" });
layer.append(scroller);
root.append(layer);
const origin = document.createElement("div");
origin.className = "acpmux-minimap";
Object.assign(origin.style, { position: "absolute", inset: "0", height: "auto" });
scroller.append(origin);
const view = createRoot(origin);

type Props = { side: "left" | "right"; prompt?: string; reply: string; center: number; x: number };
let last: Props | undefined;
const w = window as unknown as {
  __card(props: Props): Promise<void>;
  __expected(): { top: number; edge: number };
  __actual(): { top: number; left: number; right: number };
};
w.__card = (props) =>
  new Promise((resolve) => {
    last = props;
    view.render(
      <PreviewCard
        id="card"
        side={props.side}
        x={props.x}
        center={props.center}
        viewportHeight={VIEWPORT}
        scroller={scroller}
        prompt={props.prompt}
        reply={replyPreview(props.reply)}
        onPointerLeave={() => {}}
      />,
    );
    requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
  });
/// Where the card's top and its rail-side edge belong, from its height now (model.ts cardOffset).
w.__expected = () => {
  const card = document.querySelector<HTMLElement>(".acpmux-minimap__card")!;
  const frame = layer.getBoundingClientRect();
  const top = frame.top + cardOffset(last!.center, card.offsetHeight, VIEWPORT);
  const edge = last!.side === "left" ? frame.left + last!.x : frame.right - last!.x;
  return { top, edge };
};
w.__actual = () => {
  const box = document.querySelector<HTMLElement>(".acpmux-minimap__card")!.getBoundingClientRect();
  return { top: box.top, left: box.left, right: box.right };
};
document.documentElement.dataset.harnessReady = "true";
