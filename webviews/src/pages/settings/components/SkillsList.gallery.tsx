// l10n-allow-file: gallery fixtures (sample skills), not shipped UI.
// Settings > Skills' layouts, side by side for the pick (rulebook: more than two versions in the
// gallery). Shipped: `list`. It keeps Settings' one row shape (title over a muted line, one trailing
// control column, design/settings.md "Columns"), so 50+ skills scan as one column of names under
// harness and source headers and fit a narrow settings page; `tiles` spends two columns and twice the
// height per skill, so a long list scrolls far and the sources blur together; `split` hides each
// skill's source and switch behind a selection, so turning several off takes a click each to reach.
import { componentEntry } from "../../../gallery/format";
import { mockManySkills, mockSkills } from "../mockProvider";
import type { SkillsLayout } from "./SkillsCard";

type Props = { layout: SkillsLayout; many?: boolean; empty?: boolean; unavailable?: boolean };

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { SkillsPanel } = await import("./SkillsCard");
  return function SkillsLayouts({ layout, many, empty, unavailable }: Props) {
    const state = unavailable
      ? { available: false }
      : empty
        ? { available: true, home: "/Users/sam", projects: [], skills: [] }
        : many
          ? mockManySkills()
          : mockSkills();
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <SkillsPanel state={state} loading={false} layout={layout} onRun={async () => ({})} />
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.skills-layouts",
  title: "Skills layouts",
  area: "Settings",
  height: 640,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/SkillsCard.tsx#SkillsPanel"],
  load,
  styles: () => import("../page.css"),
  variants: {
    list: { note: "Shipped: one dense row per skill under harness and source headers.", props: { layout: "list" } },
    "list-many": { note: "Shipped layout at 60 skills.", props: { layout: "list", many: true } },
    tiles: { note: "Two columns of tiles, each with its switch.", props: { layout: "tiles" } },
    "tiles-many": { note: "Tiles at 60 skills.", props: { layout: "tiles", many: true } },
    split: {
      note: "Names on the left, the selected skill's file, description and actions on the right.",
      props: { layout: "split" },
    },
    "split-many": { note: "Split at 60 skills.", props: { layout: "split", many: true } },
    empty: { note: "No skills.", props: { layout: "list", empty: true } },
    unavailable: { note: "Daemon not connected.", props: { layout: "list", unavailable: true } },
  },
});
