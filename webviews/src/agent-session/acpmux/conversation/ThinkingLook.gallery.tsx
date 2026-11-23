// l10n-allow-file: gallery fixtures for the thinking look.
// The thinking look's settings (thinkingLook.ts), off by default, on the real shimmer (ShimmerText.tsx on
// its cadence controller) and the real Jump to latest button (VirtualTranscript.tsx JumpToLatest): the
// running line, a running tool row under it and the button while the agent works. `default` is what
// cmux ships (the one-second pass every four seconds, the band half the line, the arrow); `claude` is the
// Claude look's values (a continuous eased pass every 1250 ms, an 80 px band, the working dots); `quick`
// and `slow` compare two other paces; `reduced-motion` is the still frame of the Claude look.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { JumpToLatest } from "../VirtualTranscript";
import { LiveShimmer } from "./LiveShimmer";
import { RowShimmer } from "./ShimmerText";
import {
  configureThinkingLook,
  THINKING_JUMP_BUTTON_KEY,
  THINKING_SHIMMER_BAND_KEY,
  THINKING_SHIMMER_KEY,
  THINKING_SHIMMER_PERIOD_KEY,
} from "./thinkingLook";

type Props = {
  /** The four settings as the host pushes them; absent is cmux's defaults. */
  settings?: Record<string, unknown>;
  /** The host's Reduce Motion push: `data-status-indicators="static"`. */
  still?: boolean;
  /** Running tool rows above the line (the per-frame cost check draws 20). */
  rows?: number;
};

const LINE = "Reading note and passthrough";
const ROW = "Reading dots.jpg";

function Fixture({ settings, still = false, rows = 1 }: Props) {
  // Before the first render, as the host's display push lands before the pane mounts.
  useState(() => {
    configureThinkingLook(settings ?? {});
    if (still) document.documentElement.dataset.statusIndicators = "static";
    return null;
  });
  return (
    <div style={{ position: "relative", height: 130 + rows * 22, padding: "16px 24px", overflow: "hidden" }}>
      <div className="cv-tools">
        {Array.from({ length: rows }, (_, index) => {
          const words = rows > 1 ? `${ROW} ${index + 1}` : ROW;
          return (
            <div key={words} className="cv-tool is-live">
              <span className="cv-tool__text">
                {words}
                <RowShimmer>{words}</RowShimmer>
              </span>
            </div>
          );
        })}
      </div>
      <div className="cv-worked cv-worked--live">
        <span className="cv-shimmer__row">
          <output className="cv-thinking is-shimmer">
            <LiveShimmer label={LINE} />
          </output>
          <span className="cv-worked__time">28s</span>
        </span>
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          82.6K tokens
        </span>
      </div>
      <JumpToLatest shown working lift={0} onJump={() => {}} />
    </div>
  );
}

const CLAUDE = {
  [THINKING_SHIMMER_KEY]: "continuous",
  [THINKING_SHIMMER_PERIOD_KEY]: 1250,
  [THINKING_SHIMMER_BAND_KEY]: 80,
  [THINKING_JUMP_BUTTON_KEY]: "dots",
};

export default componentEntry<Props>({
  id: "agent-pane.thinking-look",
  title: "Thinking look (shimmer pace, band, Jump to latest dots)",
  area: "Agent pane",
  pane: true,
  height: 600,
  widths: { narrow: 360, normal: 560 },
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../../../ui/glass/glass.css"),
      import("../jumpPair.css"),
    ]),
  covers: [
    "agent-session/acpmux/conversation/thinkingLook.ts",
    "agent-session/acpmux/conversation/shimmerCadence.ts",
    "agent-session/acpmux/conversation/JumpDots.tsx",
  ],
  keywords: ["thinking", "shimmer", "sweep", "pace", "band", "claude", "jump", "dots", "look"],
  variants: {
    default: {
      props: {},
      note: "cmux's defaults, unchanged: a one-second pass every four seconds, the band half the line, the arrow.",
    },
    claude: {
      props: { settings: CLAUDE },
      note: "The Claude look: a continuous eased pass every 1250 ms, an 80 px band, Jump to latest's working dots.",
    },
    quick: {
      props: { settings: { ...CLAUDE, [THINKING_SHIMMER_PERIOD_KEY]: 900, [THINKING_SHIMMER_BAND_KEY]: 56 } },
      note: "A quicker pace: a pass every 900 ms, a 56 px band.",
    },
    slow: {
      props: { settings: { ...CLAUDE, [THINKING_SHIMMER_PERIOD_KEY]: 1800, [THINKING_SHIMMER_BAND_KEY]: 120 } },
      note: "A slower pace: a pass every 1800 ms, a 120 px band.",
    },
    "default-20-rows": {
      props: { rows: 20 },
      note: "cmux's defaults on 20 running rows, the per-frame cost check's baseline.",
    },
    "claude-20-rows": {
      props: { settings: CLAUDE, rows: 20 },
      note: "The Claude look on 20 running rows: the per-frame cost check (every band is one compositor loop).",
    },
    "reduced-motion": {
      props: { settings: CLAUDE, still: true },
      note: "Reduce Motion or static status indicators: the dim words and even dots, still.",
    },
  },
  load: () => Promise.resolve(Fixture),
});
