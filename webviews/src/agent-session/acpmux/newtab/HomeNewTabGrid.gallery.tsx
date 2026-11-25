// l10n-allow-file: gallery fixture labels, not shipped UI.
//
// Home and New Tab rows on the layout grid (leo-workspace design/grid.md sections 1 and 3): the
// Home lists and the All chats list side by side, as shipped and as they drew before the grid
// migration, plus the other on-grid options that were weighed. Each variant only swaps the row
// metrics with a scoped stylesheet; the components and their data are the existing gallery
// fixtures (HomeLists `baseline`, AllChatsList `leads`).
import type { ComponentProps, ComponentType } from "react";
import { componentEntry } from "../../../gallery/format";
import homeEntry from "../HomeLists.gallery";
import allEntry from "./AllChatsList.gallery";
import type { HomeLists } from "../HomeLists";
import type { AllChatsList } from "./AllChatsList";

type Grid = "shipped" | "before" | "home-40" | "radius-4" | "radius-8";
type Props = { grid: Grid };

// The values this branch replaced, scoped to the gallery stage.
const BEFORE = `
.acpmux-home-list{padding:6px;border-radius:18px}
.acpmux-home-label{padding:4px 10px 2px;font-weight:500}
.acpmux-home-row{height:40px;border-radius:10px;font-size:var(--text-field)}
.acpmux-home-meta{font-size:var(--text-body)}
.acpmux-home-inbox-row,.acpmux-home-inbox-open{border-radius:10px}
.nt-all-row,.nt-all-group{gap:10px;border-radius:8px}
`;

const CSS: Record<Grid, string> = {
  shipped: "",
  before: BEFORE,
  // Home rows keep their 40 px height and field type, only the radius and inset move onto the grid.
  "home-40": `.acpmux-home-row{height:40px;font-size:var(--text-field)}`,
  // All chats rows at the popup rows' 4 radius instead of the control's 6.
  "radius-4": `.nt-all-row,.nt-all-group{border-radius:4px}`,
  // All chats rows keep their old 8 radius, with the 8 gap.
  "radius-8": `.nt-all-row,.nt-all-group{border-radius:8px}`,
};

const homeProps = homeEntry.variants.baseline!.props as ComponentProps<typeof HomeLists>;
const allProps = allEntry.variants.leads!.props as ComponentProps<typeof AllChatsList>;

const note = {
  shipped:
    "Shipped: Home rows 32 tall at body type, radius 12 in a list with a 4 inset and radius 16 (concentric); the list header on the rows' text line; All chats rows with an 8 gap (text 32 from the highlight) at radius 6.",
  before:
    "Before the grid migration: Home rows 40 tall at 14 px, radius 10 in a 6 inset list at 18; All chats rows with a 10 gap at radius 8.",
  "home-40":
    "Option weighed: Home rows stay 40 tall at field type (14) with the on-grid inset and radius. Rejected: grid.md section 3 puts Home's lists on 28/32 rows, and the inbox rows above already draw at body type.",
  "radius-4":
    "Option weighed: All chats rows at radius 4, like popup rows. Rejected: these rows sit on the page, not in a 4-inset popup, so the concentric rule does not apply; 6 is the control radius.",
  "radius-8": "Option weighed: All chats rows keep radius 8 with the on-grid gap.",
} satisfies Record<Grid, string>;

export default componentEntry<Props>({
  id: "agent-pane.home-newtab-grid",
  title: "Home and New Tab rows on the grid",
  area: "Agent pane",
  pane: true,
  height: 760,
  widths: { narrow: 420, normal: 620, wide: 820 },
  anchors: [{ selector: ".home-newtab-grid" }],
  covers: ["agent-session/acpmux/HomeLists.tsx#HomeLists", "agent-session/acpmux/newtab/AllChatsList.tsx#AllChatsList"],
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  load: async () => {
    const [Home, All] = (await Promise.all([homeEntry.load(), allEntry.load()])) as [
      ComponentType<ComponentProps<typeof HomeLists>>,
      ComponentType<ComponentProps<typeof AllChatsList>>,
    ];
    return ({ grid }: Props) => (
      <div className="home-newtab-grid" style={{ display: "flex", flexDirection: "column", gap: 24 }}>
        <style>{CSS[grid]}</style>
        <Home {...homeProps} />
        <div style={{ height: 300, display: "flex", flexDirection: "column" }}>
          <All {...allProps} />
        </div>
      </div>
    );
  },
  variants: Object.fromEntries(
    (Object.keys(CSS) as Grid[]).map((grid) => [grid, { note: note[grid], props: { grid } }]),
  ) as Record<Grid, { note: string; props: Props }>,
});
