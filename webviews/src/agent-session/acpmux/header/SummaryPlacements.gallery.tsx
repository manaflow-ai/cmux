// l10n-allow-file: gallery fixture data, not shipped UI.
// Where the chat's rolling summary and next action can live in the pane (Leo, 2026-11-23: "unwilling to accept a
// banner at the top of a single fucking line that gets cut off and also inadvertently shifts the fucking buttons
// on the top right down with it"). Each variant is one pane width and one banner length, with every placement
// stacked under its cost: A is what ships (ChatSummaryLine.tsx, the real component); B, C and D are static mocks.
import type { ReactNode } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { BANNERS, PaneHeader, type Banner } from "./headerGalleryFixtures";
import type { ChatSummary } from "./ChatSummaryLine";
import { ThreadTitle } from "./ThreadTitle";
import "./SummaryPlacements.gallery.css";

type Props = { width: number; banner: Exclude<Banner, "none"> };

const noop = () => undefined;

function Cell({ letter, name, cost, children }: { letter: string; name: string; cost: string; children: ReactNode }) {
  return (
    <div className="sp-cell" data-placement={letter}>
      <div className="sp-label">
        <span>
          <b>
            {letter}. {name}
          </b>
        </span>
        <span>Cost: {cost}</span>
      </div>
      {children}
    </div>
  );
}

const Parts = ({ summary }: { summary: ChatSummary }) => (
  <>
    {summary.text}
    {summary.next ? (
      <>
        {" "}
        <em>→</em> <strong>{summary.next}</strong>
      </>
    ) : null}
  </>
);

/// B: one line beside the title; hover opens the whole text in an overlay under it, nothing else moves.
function HoverExpand({ summary, open }: { summary: ChatSummary; open?: boolean }) {
  return (
    <span className="acpmux-header-status-content">
      <ThreadTitle title="Remove send-scroll" onRename={noop} />
      <span className="sp-b" data-open={open ? "" : undefined}>
        <button type="button" className="sp-b__line">
          <Parts summary={summary} />
        </button>
        <span className="sp-b__card" role="tooltip">
          {summary.text}
          <strong>Next: {summary.next}</strong>
        </span>
      </span>
    </span>
  );
}

/// C: the title alone in the header; the summary is the composer footer's status dot's hover rundown.
function ComposerStatus({ summary, open, width }: { summary: ChatSummary; open?: boolean; width: number }) {
  return (
    <div style={{ width, paddingBottom: 6 }} className="sp-frame">
      <div className="sp-composer">
        <div className="sp-composer__input">Ask for follow-up changes</div>
        <div className="sp-composer__footer">
          <span className="sp-dot-wrap" data-open={open ? "" : undefined}>
            <button type="button" className="sp-dot-btn" data-open={open ? "" : undefined}>
              <span className="sp-dot" />
              Working
            </button>
            <span className="sp-rundown" role="tooltip">
              <p>{summary.text}</p>
              <p>Next: {summary.next}</p>
            </span>
          </span>
          <span className="sp-composer__spacer" />
          <span>Opus</span>
        </div>
      </div>
    </div>
  );
}

/// D: the title over a small summary line in one block; the header is 40px.
function TwoLine({ summary }: { summary: ChatSummary }) {
  return (
    <span className="sp-d">
      <span className="sp-d__title">Remove send-scroll</span>
      <span className="sp-d__sub">
        <Parts summary={summary} />
      </span>
    </span>
  );
}

function Placements({ width, banner }: Props) {
  const summary = BANNERS[banner]!;
  return (
    <div className="sp-stack" style={{ width: width + 16 }}>
      <Cell
        letter="A"
        name="Fits whole, else a chip with a hover card (ships)"
        cost="a 24px tool in the row when it does not fit; the text is one hover or click away, never on screen at rest."
      >
        <div className="sp-frame" style={{ width }}>
          <PaneHeader mode="ownrow" width={width} banner={summary} />
        </div>
      </Cell>
      <Cell
        letter="B"
        name="Hover-expand: one line that opens downward into an overlay"
        cost="at rest the line is still cut off with an ellipsis, the thing he refuses; no layout shift on hover."
      >
        <div className="sp-frame" style={{ width }}>
          <PaneHeader mode="ownrow" width={width} banner={summary} statusContent={<HoverExpand summary={summary} />} />
        </div>
      </Cell>
      <Cell
        letter="B"
        name="B, hovered"
        cost="the overlay covers the transcript's first line while the pointer is on it."
      >
        <div className="sp-frame" style={{ width, height: 92 }}>
          <PaneHeader
            mode="ownrow"
            width={width}
            banner={summary}
            statusContent={<HoverExpand summary={summary} open />}
          />
        </div>
      </Cell>
      <Cell
        letter="C"
        name="Composer status: the summary moves to the footer's status dot"
        cost="the header holds only the title and tools (no banner, no shift); the banner leaves the top of the pane, and the rundown shows only on hover (PR #51343 one status dot)."
      >
        <ComposerStatus summary={summary} width={width} />
      </Cell>
      <Cell letter="C" name="C, hovered" cost="same, the dot's rundown over the composer.">
        <div style={{ paddingTop: 56 }}>
          <ComposerStatus summary={summary} open width={width} />
        </div>
      </Cell>
      <Cell
        letter="D"
        name="Two-line title block, header 40px"
        cost="12px of height in every header; the summary line is still cut off at narrow widths, but in its own row, so the buttons never move."
      >
        <div className="sp-frame" style={{ width }}>
          <PaneHeader
            mode="ownrow"
            width={width}
            banner={summary}
            extraHeaderStyle={{ height: 40, flexBasis: 40 }}
            statusContent={<TwoLine summary={summary} />}
          />
        </div>
      </Cell>
    </div>
  );
}

/// A's chip or line card: the real hover card, opened for the capture.
const openA: Play = async (ctx) => {
  await ctx.hover({
    selector: '[data-placement="A"] .acpmux-chat-summary, [data-placement="A"] .acpmux-chat-summary-chip',
  });
};

const v = (width: number, banner: Props["banner"], note: string, play?: Play) => ({
  props: { width, banner },
  note,
  play,
});

export default componentEntry<Props>({
  id: "agent-pane.summary-placements-v2",
  title: "Chat summary placements (v2)",
  area: "Agent pane",
  pane: true,
  height: 900,
  widths: { narrow: 400, normal: 560, wide: 860 },
  covers: ["agent-session/acpmux/header/ChatSummaryLine.tsx#ChatSummaryLine"],
  load: async () => Placements,
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  variants: {
    "w360-short": v(360, "short", "360px, short banner (Tests pass → Open the PR): A, B, C, D."),
    "w360-long": v(
      360,
      "long",
      "360px, the screenshot's long banner: A folds to the chip, B cuts the line, D cuts the sub line.",
    ),
    "w800-short": v(800, "short", "800px, short banner: every placement fits."),
    "w800-long": v(800, "long", "800px, long banner."),
    "w360-long-a-card": v(360, "long", "360px, long banner, A's hover card open.", openA),
  },
});
