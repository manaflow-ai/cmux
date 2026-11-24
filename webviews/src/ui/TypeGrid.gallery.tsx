// Grid line heights (experiments.typeGrid, off by default; design C1, cmuxterm-hq
// docs/design/design-system-decisions/C-type-fonts-spacing-rows.md): today's line heights and the
// 4-grid ones side by side, on every step of the type scale, with a wrapped body paragraph (the text
// the design says grows: "Only wrapped text grows ... by 2 px per line") and a one-line 28 row (which
// must not grow: "rows are sized by the control height (28), not by line height plus padding").
// l10n-allow-file: gallery fixture labels, not shipped UI.
import { useLayoutEffect } from "react";
import { componentEntry } from "../gallery/format";
import { TYPE_GRID_ATTRIBUTE } from "./typeGrid";

type Props = { grid?: boolean; scale?: number };

const STEPS = ["caption", "detail", "body", "field", "title", "heading"] as const;

function TypeGridGallery({ grid = true, scale = 1 }: Props) {
  useLayoutEffect(() => {
    const root = document.documentElement;
    if (grid) root.setAttribute(TYPE_GRID_ATTRIBUTE, "");
    else root.removeAttribute(TYPE_GRID_ATTRIBUTE);
    root.style.setProperty("--cmux-interface-scale", String(scale));
    return () => {
      root.removeAttribute(TYPE_GRID_ATTRIBUTE);
      root.style.removeProperty("--cmux-interface-scale");
    };
  }, [grid, scale]);
  return (
    <div className="type-grid-gallery">
      {STEPS.map((step) => (
        <div key={step} className="type-grid-gallery-step" data-step={step}>
          <span
            style={{ fontSize: `var(--text-${step})`, lineHeight: `var(--text-${step}--line-height)` }}
          >{`The ${step} step`}</span>
        </div>
      ))}
      <p className="type-grid-gallery-wrap">
        A wrapped body paragraph, as in a two-line toast, a dialog body or a Settings help line: each line sits on the
        body step's line height, so turning the switch on adds two points per line here and nowhere else.
      </p>
      <div className="type-grid-gallery-row">A one-line 28 row keeps its height</div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.type-grid",
  title: "Grid line heights (experiments.typeGrid)",
  area: "UI primitives",
  height: 420,
  widths: { narrow: 320, normal: 560, wide: 800 },
  covers: ["ui/typeGrid.css", "ui/typeGrid.ts#applyTypeGrid"],
  load: async () => TypeGridGallery,
  styles: () => import("./TypeGrid.gallery.css"),
  variants: {
    today: { props: { grid: false } },
    grid: { props: { grid: true } },
    "grid-large": { props: { grid: true, scale: 1.25 } },
  },
});
