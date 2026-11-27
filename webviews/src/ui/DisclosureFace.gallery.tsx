// l10n-allow-file: gallery labels are fixture content, not shipped UI.
// The room between a control's words and its chevron (design/chevrons.md; Leo, 2026-11-27:
// "these chevrons are too close dont we have any guidelines for these yet?"). Each variant sets
// --ui-disclosure-gap, the box gap before the registry chevron; the selected one is the default.
// The first row is the old text "⌄" for comparison; the capped chip shows the label ellipsizing
// before the chevron. test/disclosure-chevron-gap.test.ts measures the shipped chips.
import type { CSSProperties } from "react";
import { DisclosureFace } from "../agent-session/acpmux/DisclosureFace";
import { componentEntry } from "../gallery/format";

type Props = { gap?: string };

function Chips({ gap }: Props) {
  const style = gap ? ({ "--ui-disclosure-gap": gap } as CSSProperties) : undefined;
  return (
    <div className="dface-stage" style={style}>
      <div className="dface-row">
        <span className="dface-caption">Before (text glyph)</span>
        <button type="button" className="dface-chip">
          acpmux<span className="dface-old-chevron">⌄</span>
        </button>
        <button type="button" className="dface-chip">
          <span className="dface-badge">38</span>
          <span className="dface-muted">· cloud-mac-2</span>
          <span className="dface-old-chevron">⌄</span>
        </button>
      </div>
      <div className="dface-row">
        <span className="dface-caption">Shared face</span>
        <button type="button" className="dface-chip" data-testid="dface-name">
          <DisclosureFace>acpmux</DisclosureFace>
        </button>
        <button type="button" className="dface-chip" data-testid="dface-where">
          <span className="dface-badge">38</span>
          <DisclosureFace labelClassName="dface-muted">· cloud-mac-2</DisclosureFace>
        </button>
      </div>
      <div className="dface-row">
        <span className="dface-caption">Cut at 120px</span>
        <button type="button" className="dface-chip" data-cap="" data-testid="dface-cut">
          <span className="dface-badge">38</span>
          <DisclosureFace labelClassName="dface-muted">· cloud-mac-2-with-a-long-name</DisclosureFace>
        </button>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.disclosure-face",
  title: "Disclosure chevron gap",
  area: "UI primitives",
  height: 220,
  widths: { narrow: 340, normal: 540 },
  covers: ["agent-session/acpmux/DisclosureFace.tsx#DisclosureFace"],
  load: async () => Chips,
  styles: () => Promise.all([import("./ui.css"), import("./DisclosureFace.gallery.css")]),
  variants: {
    "space-1": {
      props: {},
      note: "Selected default: one spacing step (4px) between the label's box and the chevron's; about 6px of visible room, as the transcript's ChatGPT-style chevrons.",
    },
    half: {
      props: { gap: "2px" },
      note: "Half a step (2px): about 4px of room; the chevron reads as part of the word.",
    },
    "space-2": {
      props: { gap: "var(--ds-space-2)" },
      note: "Two steps (8px): about 10px of room; the chevron starts to float away from its label.",
    },
  },
});
