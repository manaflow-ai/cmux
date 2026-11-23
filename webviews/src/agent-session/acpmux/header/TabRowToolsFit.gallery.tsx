// l10n-allow-file: gallery fixture data, not shipped UI.
// The tab row's tools slot and the pane's fit rule (Leo, 2026-11-22: "the icons on the top right have gotten displaced
// due to putting things on a line ... we need to have a proper way to do ui so that when anybody wants to adjust or
// customize things like this, it is done easily properly"). The page reports the width of the slot marked
// `data-tab-row-slot="tools"` (tabRow.ts useTabRowTools); the pane keeps the tools in the tab row only while that need
// is at most half the pane (PaneTabRowSharing.fitsTabRow), else they drop to a second row under the tabs. The "before"
// variants put the rolling summary in the slot, as the shipped build did; "after" leaves the slot to the tools.
import { useLayoutEffect, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { ChatSummaryLine } from "./ChatSummaryLine";
import "./header.css";

type Props = { paneWidth: number; summaryInSlot: boolean };

const SUMMARY = { text: "Fixed the parser and pushed it. CI is still running.", next: "Merge the PR once CI is green" };
const TOOLS = ["≡", "±", ">_", "◍", "…"];

function TabRowToolsFit({ paneWidth, summaryInSlot }: Props) {
  const slot = useRef<HTMLDivElement>(null);
  const [need, setNeed] = useState(0);
  useLayoutEffect(() => {
    // The page's own measure (tabRow.ts): the slot's box plus TAB_ROW_GAP.
    setNeed(Math.round(slot.current?.getBoundingClientRect().width ?? 0) + 4);
  }, [paneWidth, summaryInSlot]);
  const fits = need <= paneWidth / 2;
  return (
    <div style={{ width: paneWidth, display: "grid", gap: 8, padding: 8 }}>
      <div className="acpmux-shell" style={{ ["--acpmux-tab-row-height" as string]: "34px" }}>
        <header className="acpmux-header" data-tab-row="" style={{ display: "flex", justifyContent: "flex-end" }}>
          <div className="acpmux-handoff-header-tools" ref={slot} data-tab-row-slot="tools">
            {summaryInSlot ? <ChatSummaryLine summary={SUMMARY} /> : null}
            {TOOLS.map((glyph) => (
              <span key={glyph} className="acpmux-header-tool" style={{ width: 24, textAlign: "center" }}>
                {glyph}
              </span>
            ))}
          </div>
        </header>
      </div>
      <small data-fit={fits ? "tab-row" : "second-row"} style={{ opacity: 0.8 }}>
        slot {need}px of {paneWidth / 2}px allowed: {fits ? "tools stay in the tab row" : "tools drop to a second row"}
      </small>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.tab-row-tools-fit",
  title: "Tab row tools slot: what the fit rule measures",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 480, normal: 760 },
  anchors: [{ selector: "[data-tab-row-slot]" }],
  covers: ["agent-session/acpmux/header/tabRow.ts"],
  styles: () => Promise.all([import("../styles.css"), import("./header.css")]),
  load: async () => TabRowToolsFit,
  variants: {
    "before-medium": {
      props: { paneWidth: 560, summaryInSlot: true },
      note: "Before: the summary's up-to-300px line widens the slot past half the pane, so the tools drop to a second row.",
    },
    "after-medium": {
      props: { paneWidth: 560, summaryInSlot: false },
      note: "After: the slot holds the tools only; they stay in the tab row.",
    },
    "after-narrow": {
      props: { paneWidth: 300, summaryInSlot: false },
      note: "After, in a narrow pane: five 24px tools need less than half of it.",
    },
  },
});
