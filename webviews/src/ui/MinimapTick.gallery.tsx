// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useRef, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { MinimapTick } from "./MinimapTick";

type Props = {
  count?: number;
  initial?: number;
};

function MinimapTickGallery({ count = 6, initial = 2 }: Props) {
  const [active, setActive] = useState(Math.min(initial, count - 1));
  const [event, setEvent] = useState("Ready");
  const ticks = useRef<Array<HTMLButtonElement | null>>([]);
  const move = (index: number) => {
    const next = Math.max(0, Math.min(count - 1, index));
    setActive(next);
    setEvent(`Turn ${next + 1}`);
    requestAnimationFrame(() => ticks.current[next]?.focus({ preventScroll: true }));
  };
  return (
    <div className="minimap-tick-gallery-stage">
      <div className="minimap-tick-gallery-copy">
        <strong>Transcript minimap</strong>
        <span>One active tick stays in the Tab order while arrows move through turns.</span>
      </div>
      <ul className="minimap-tick-gallery-strip" aria-label="Transcript turns">
        {Array.from({ length: count }, (_, index) => (
          <li key={index}>
            <MinimapTick
              ref={(element) => {
                ticks.current[index] = element;
              }}
              index={index}
              last={count - 1}
              active={index === active}
              aria-label={`Turn ${index + 1}`}
              aria-current={index === active ? "step" : undefined}
              onClick={() => move(index)}
              keyboard={(event) => {
                if (event.key === "ArrowUp") move(index - 1);
                else if (event.key === "ArrowDown") move(index + 1);
                else if (event.key === "Home") move(0);
                else if (event.key === "End") move(count - 1);
              }}
            >
              <span aria-hidden="true" />
            </MinimapTick>
          </li>
        ))}
      </ul>
      <output className="minimap-tick-gallery-receipt" data-testid="minimap-tick-gallery-receipt" aria-live="polite">
        {event}
      </output>
    </div>
  );
}

const active = (ctx: Parameters<Play>[0], index: number) => {
  const target = ctx.find({ role: "button", name: `Turn ${index + 1}` });
  return (
    target.getAttribute("aria-current") === "step" &&
    target.getAttribute("tabindex") === "0" &&
    ctx.document.activeElement === target
  );
};

const arrows: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Turn 3" });
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => active(ctx, 3));
  await ctx.press("ArrowUp");
  await ctx.waitFor(() => active(ctx, 2));
};

const edges: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Turn 3" });
  await ctx.press("Home");
  await ctx.waitFor(() => active(ctx, 0));
  await ctx.press("End");
  await ctx.waitFor(() => active(ctx, 5));
};

const click: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Turn 5" });
  await ctx.waitFor(() => ctx.find({ testId: "minimap-tick-gallery-receipt" }).textContent === "Turn 5");
};

const oneTabStop: Play = async (ctx) => {
  await ctx.waitFor(() => {
    const stops = ctx.document.querySelectorAll('.minimap-tick-gallery-strip button[tabindex="0"]');
    const current = ctx.document.querySelector('.minimap-tick-gallery-strip button[aria-current="step"]');
    return stops.length === 1 && stops[0] === current;
  });
};

export default componentEntry<Props>({
  id: "ui.minimap-tick",
  title: "Transcript minimap tick",
  area: "UI primitives",
  height: 300,
  widths: { narrow: 320, normal: 480, wide: 720 },
  anchors: [{ selector: ".minimap-tick-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Moving the active tick must not move the stable receipt anchor." },
    longFrameFailMs: { value: 33, reason: "Minimap keyboard navigation should stay within two display frames." },
    settleMaxMs: { value: 250, reason: "Minimap navigation is a local interaction." },
  },
  covers: ["ui/MinimapTick.tsx#MinimapTick"],
  load: async () => MinimapTickGallery,
  styles: () => Promise.all([import("./ui.css"), import("./MinimapTick.gallery.css")]),
  variants: {
    initial: { props: {} },
    arrows: { props: {}, play: arrows },
    "home-end": { props: {}, play: edges },
    click: { props: {}, play: click },
    "one-tab-stop": { props: {}, play: oneTabStop },
    compact: { props: { count: 3, initial: 1 }, play: oneTabStop },
  },
});
