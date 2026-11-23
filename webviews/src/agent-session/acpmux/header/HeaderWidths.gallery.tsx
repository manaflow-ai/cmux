// l10n-allow-file: gallery fixture data, not shipped UI.
// The real chat header (ChatHeaderStatus, ThreadTitle, ChatSummaryLine, ChatHeaderTools with its "..." menu) at
// the pane widths that broke it. Leo, 2026-11-23: "unwilling to accept a banner at the top of a single fucking
// line that gets cut off and also inadvertently shifts the fucking buttons on the top right down with it ... the
// fucking buttons on the top right NEED to be done right, especially when things are at compressed width panes."
// Each variant is one pane width in one mode and draws the three banner states stacked: no banner, a short one,
// the long one of his screenshot. Own row: the title with the summary beside it (the whole line, or the chip).
// Tab row: no title, the summary the chip before the tools, the native tab strip's geometry mocked over the
// slot. At every width the tools stay on the header's one row at the same place whatever the banner says, and
// the quick actions fold into "..." as the pane narrows.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { BANNERS, BANNER_LABEL, PaneHeader, type Banner, type HeaderMode } from "./headerGalleryFixtures";

type Props = { mode: HeaderMode; width: number };

const ORDER: Banner[] = ["none", "short", "long"];

function HeaderWidths({ mode, width }: Props) {
  return (
    <div style={{ display: "grid", gap: 14, padding: "8px 8px 96px", width: width + 16 }}>
      {ORDER.map((banner) => (
        <div key={banner} style={{ display: "grid", gap: 3 }} data-banner={banner}>
          <small style={{ opacity: 0.65 }}>
            {mode === "ownrow" ? "own row" : "tab row"}, {width}px, {BANNER_LABEL[banner]}
          </small>
          <div style={{ outline: "1px solid var(--agent-border)" }}>
            <PaneHeader mode={mode} width={width} banner={BANNERS[banner]} />
          </div>
        </div>
      ))}
    </div>
  );
}

/// The point of the gallery: whatever the banner says, the tools' row is the same on one line, never
/// below the header's row, and never wider or further left than with no banner.
const toolsStayPut: Play = async (ctx) => {
  const rows = [...ctx.document.querySelectorAll<HTMLElement>("[data-banner]")];
  const boxes = rows.map((row) => {
    const header = row.querySelector<HTMLElement>(".acpmux-header")!;
    const tools = row.querySelector<HTMLElement>(".acpmux-header-tools")!;
    const mine = tools.getBoundingClientRect();
    const mineHeader = header.getBoundingClientRect();
    if (mine.bottom > mineHeader.bottom + 0.5 || mine.top < mineHeader.top - 0.5)
      throw new Error(`the tools leave the header's row (${row.dataset.banner})`);
    return mine;
  });
  const [first] = boxes;
  for (const box of boxes) {
    if (Math.abs(box.left - first!.left) > 1 || Math.abs(box.top - first!.top) > 0.5)
      throw new Error("the tools moved with the banner");
  }
};

const variant = (mode: HeaderMode, width: number, note: string) => ({
  props: { mode, width },
  note,
  play: toolsStayPut,
});

export default componentEntry<Props>({
  id: "agent-pane.header-widths",
  title: "Chat header at compressed widths (banner states)",
  area: "Agent pane",
  pane: true,
  height: 330,
  widths: { narrow: 320, normal: 520, wide: 860 },
  anchors: [{ selector: ".acpmux-header-tools" }],
  covers: [
    "agent-session/acpmux/header/ChatSummaryLine.tsx#ChatSummaryLine",
    "agent-session/acpmux/header/ChatHeaderTools.tsx#ChatHeaderTools",
    "agent-session/acpmux/header/ChatHeaderStatus.tsx",
    "agent-session/acpmux/header/ThreadTitle.tsx#ThreadTitle",
    "agent-session/acpmux/header/headerOverflow.ts",
  ],
  load: async () => HeaderWidths,
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  variants: {
    "ownrow-280": variant(
      "ownrow",
      280,
      "Own row, 280px: the title keeps its room, quick actions fold into the ..., the banner is the chip (or nothing); the buttons are on the one row.",
    ),
    "ownrow-360": variant(
      "ownrow",
      360,
      "Own row, 360px: the short banner fits whole beside the title only if the room holds it, else the chip; the long one is always the chip.",
    ),
    "ownrow-480": variant(
      "ownrow",
      480,
      "Own row, 480px: the short banner shows whole; the long one folds to the chip rather than cut off.",
    ),
    "ownrow-800": variant(
      "ownrow",
      800,
      "Own row, 800px: both banners may show whole; every quick action is in the row.",
    ),
    "tabrow-280": variant(
      "tabrow",
      280,
      "Tab row, 280px: the native tabs on the left, the chip and the folded tools on the right; the same tools for every banner.",
    ),
    "tabrow-360": variant(
      "tabrow",
      360,
      "Tab row, 360px: the summary is one more square tool, so the tools' width never depends on the text.",
    ),
    "tabrow-480": variant("tabrow", 480, "Tab row, 480px."),
    "tabrow-800": variant("tabrow", 800, "Tab row, 800px: every quick action in the row, tabs have the rest."),
  },
});
