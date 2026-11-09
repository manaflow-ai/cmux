// l10n-allow-file: gallery labels are fixture content, not shipped UI.
// The gallery stages of the ui/motion primitives (motion.gallery.css). Each entry file renders one of
// these with its variant's props; nothing here ships in a page.
import { useRef, useState } from "react";
import { cx } from "../cx";
import { DepthLayer, type DepthLook } from "./DepthLayer";
import { type IndicatorLook, type IndicatorTravel, SlidingIndicator } from "./SlidingIndicator";
import { ViewSwap, type ViewSwapLook } from "./ViewSwap";

const TABS = ["Overview", "Skills", "Gear", "Stats"] as const;

function Tabs({
  look,
  travel,
  value,
  onChange,
  chunky,
}: {
  look: IndicatorLook | "today";
  travel: IndicatorTravel;
  value: number;
  onChange: (index: number) => void;
  chunky?: boolean;
}) {
  return (
    <div
      role="tablist"
      aria-label="Character"
      className={cx("motion-demo-tabs", chunky && "motion-demo-tabs--chunky", look !== "today" && "ui-slide-host")}
      data-today={look === "today" ? "" : undefined}
    >
      {look !== "today" && <SlidingIndicator selected={value} look={look} travel={travel} />}
      {TABS.map((label, index) => (
        <button
          key={label}
          type="button"
          role="tab"
          aria-selected={index === value}
          className={cx("motion-demo-tab", look !== "today" && "ui-slide-item")}
          onClick={() => onChange(index)}
        >
          {label}
        </button>
      ))}
    </div>
  );
}

const PANELS: Record<(typeof TABS)[number], [string, string][]> = {
  Overview: [
    ["Level", "60"],
    ["Rank", "S"],
    ["Faction", "Section 6"],
  ],
  Skills: [
    ["Basic", "12 / 12"],
    ["Dodge", "12 / 12"],
    ["Chain", "12 / 12"],
  ],
  Gear: [
    ["Engine", "Sunbringer"],
    ["Disc 1", "+15"],
    ["Disc 2", "+15"],
  ],
  Stats: [
    ["HP", "5,736"],
    ["ATK", "441"],
    ["Crit rate", "51.2%"],
  ],
};

export type IndicatorDemoProps = { look: IndicatorLook | "today"; travel?: IndicatorTravel };

/** A chunky tab bar and a two-way segmented control, both on one indicator look. */
export function IndicatorDemo({ look, travel = "spring" }: IndicatorDemoProps) {
  const [tab, setTab] = useState(0);
  const [view, setView] = useState(0);
  return (
    <div className="motion-demo-stage">
      <Tabs look={look} travel={travel} value={tab} onChange={setTab} chunky />
      <div
        className={cx("motion-demo-segmented", look !== "today" && "ui-slide-host")}
        aria-label="View"
        data-today={look === "today" ? "" : undefined}
      >
        {look !== "today" && (
          <SlidingIndicator selected={view} look={look === "pill" ? "plate" : look} travel={travel} />
        )}
        {["Wire", "Session"].map((label, index) => (
          <button
            key={label}
            type="button"
            aria-pressed={index === view}
            className={cx("motion-demo-segment", look !== "today" && "ui-slide-item")}
            onClick={() => setView(index)}
          >
            {label}
          </button>
        ))}
      </div>
      <output className="motion-demo-receipt" data-testid="motion-demo-receipt">
        {TABS[tab]} · {view === 0 ? "Wire" : "Session"}
      </output>
    </div>
  );
}

export type SwapDemoProps = { look: ViewSwapLook };

/** The tab bar over a panel of stat cards that swaps with the chosen look. */
export function SwapDemo({ look }: SwapDemoProps) {
  const [tab, setTab] = useState(0);
  const name = TABS[tab]!;
  return (
    <div className="motion-demo-stage">
      <Tabs look="pill" travel="spring" value={tab} onChange={setTab} chunky />
      <ViewSwap swapKey={name} order={tab} look={look} className="motion-demo-panel">
        <div role="tabpanel" aria-label={name} className="motion-demo-cards">
          {PANELS[name].map(([label, value]) => (
            <button key={label} type="button" className="motion-demo-card" aria-label={`${label} ${value}`}>
              <span>{label}</span>
              <strong>{value}</strong>
            </button>
          ))}
        </div>
      </ViewSwap>
      <output className="motion-demo-receipt" data-testid="motion-demo-receipt">
        {name}
      </output>
    </div>
  );
}

export type HoverDemoProps = { timing: "blink" | "scale" | "slow" | "press-dip" };

/** Rows with a hover fill on their own button and an ellipsis revealed on the row's hover. */
export function HoverDemo({ timing }: HoverDemoProps) {
  const [opened, setOpened] = useState<number>();
  return (
    <div className="motion-demo-stage" data-hover-timing={timing}>
      <ul className="motion-demo-rows" aria-label="Sessions">
        {["Fix the rail", "Session Info tabs", "Motion tokens"].map((label, index) => (
          <li key={label} className="motion-demo-row ui-reveal-host">
            <span>{label}</span>
            <button
              type="button"
              className="motion-demo-more ui-hover-fill ui-reveal"
              aria-label={`More for ${label}`}
              data-popup-open={opened === index ? "" : undefined}
              onClick={() => setOpened(opened === index ? undefined : index)}
            >
              ···
            </button>
          </li>
        ))}
      </ul>
      <output className="motion-demo-receipt" data-testid="motion-demo-receipt">
        {opened === undefined ? "Nothing open" : `Menu open on row ${opened + 1}`}
      </output>
    </div>
  );
}

export type DepthDemoProps = { look: DepthLook };

/** A Home-like card with the depth layer behind its content. */
export function DepthDemo({ look }: DepthDemoProps) {
  const surface = useRef<HTMLDivElement>(null);
  return (
    <div ref={surface} className="motion-demo-depth">
      <DepthLayer look={look} surface={surface} />
      <div className="motion-demo-depth-content">
        <strong>Good evening</strong>
        <span>Three chats are running. Move the pointer over the card.</span>
      </div>
    </div>
  );
}
