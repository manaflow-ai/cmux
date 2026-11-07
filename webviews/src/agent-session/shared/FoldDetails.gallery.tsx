// l10n-allow-file: gallery fixture labels, not shipped UI.
// A page's <details> run through Session Info's fold (FoldDetails.tsx): closed, open, and held 60 ms into
// the fold on the settle (Leo, 2026-11-07: "they dont overshoot but they decelerate at the end. i think
// that might be the key").
import { componentEntry } from "../../gallery/format";
import type { Play, PlayContext } from "../../gallery/play";
import { FoldDetails } from "./FoldDetails";

function Demo() {
  return (
    <div style={{ padding: 16, width: 320 }}>
      <FoldDetails summary="Exact sizes" summaryProps={{ "data-fold-summary": "" }}>
        {["Body", "Detail", "Title", "Row height", "Icon"].map((name) => (
          <p key={name} style={{ margin: "4px 0" }}>
            {name}
          </p>
        ))}
      </FoldDetails>
      <p style={{ marginTop: 8 }}>Under the fold: moves with it.</p>
    </div>
  );
}

const summary = "[data-fold-summary]";
const settled = (ctx: PlayContext) => ctx.document.getAnimations().length === 0;

const open: Play = async (ctx) => {
  await ctx.click({ selector: summary });
  await ctx.waitFor(() => settled(ctx), { capMs: 3000 });
  if (!ctx.document.querySelector("details[open]")) throw new Error("The details did not open");
};

const midFold: Play = async (ctx) => {
  await ctx.click({ selector: summary });
  await ctx.waitFor(() => ctx.document.getAnimations().length > 0);
  for (const animation of ctx.document.getAnimations()) {
    animation.pause();
    animation.currentTime = 60;
  }
};

export default componentEntry({
  id: "shared.fold-details",
  title: "Fold details",
  area: "Agent pane",
  height: 260,
  widths: { narrow: 340 },
  covers: ["agent-session/shared/FoldDetails.tsx#FoldDetails"],
  load: async () => Demo,
  variants: {
    closed: { note: "Closed: the summary alone.", props: {} },
    open: {
      note: "Chosen. Opened: the body's height and opacity moved together on the settle, and the line under it moved on the same frames.",
      props: {},
      play: open,
    },
    "mid-fold": {
      note: "Held 60 ms into the open: most of the way there, decelerating into its end.",
      props: {},
      play: midFold,
    },
  },
});
