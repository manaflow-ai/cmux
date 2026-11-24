// l10n-allow-file: gallery of a proposal (sample customizations and setups), not shipped UI.
// The customization paradigm Leo asked for, 2026-11-24 07:32Z: "getting a proper customization
// paradigm would be better. the settings page customize is... not good."; 07:17Z: "having people be
// able to easily toggle my customieer or whatever would be god". Design note: cmuxterm-hq
// docs/design/customization-paradigm.md. Three layouts over one live preview, each as a teammate
// opens it (Leo's customizations off) and after one click on Try Leo's setup:
// - store: Raycast Store / Obsidian community plugins. A shelf of setups, a grid of customizations
//   with their after picture, the selected one's before/after and switch on the right.
// - manager: a game mod manager / VS Code profiles. One switch per row with its source and any
//   conflict, the setup picker on top, the live window beside; pointing at a row shows its
//   before/after.
// - setups: people first (Arc spaces, VS Code profile import). Pick whose setup, see what it changes
//   from yours, each change a switch, over the live result.
// Recommended: manager. It is the fewest clicks from "what is on" to "turn this off", every switch
// is visible at once like a checklist (Leo, 2026-11-22: "as few clicks as reasonable"), and the
// before/after stays one point away instead of a page away.
import { componentEntry } from "../../gallery/format";
import type { Effect } from "./customizeStudio";
import type { StudioLayout } from "./CustomizeStudio";

type Props = { layout: StudioLayout; on: Effect[]; trying?: string; selected?: Effect };

async function load() {
  const { CustomizeStudio } = await import("./CustomizeStudio");
  return function CustomizeStudioGallery(props: Props) {
    return (
      <section style={{ padding: 16 }}>
        <CustomizeStudio {...props} />
      </section>
    );
  };
}

const LEO: Effect[] = ["glass", "motion", "ember", "compact", "round", "blocks", "yours", "standup"];
const LAYOUTS: Record<StudioLayout, string> = {
  store: "Store: setups shelf, customization cards, detail with before/after",
  manager: "Manager (recommended): one switch per row, setup picker, live window beside",
  setups: "Setups: whose setup, what it changes from yours, live result",
};

const variants: Record<string, { note: string; props: Props }> = {};
for (const layout of Object.keys(LAYOUTS) as StudioLayout[]) {
  variants[`${layout}-teammate`] = {
    note: `${LAYOUTS[layout]}; a teammate's first look: everything off.`,
    props: { layout, on: [] },
  };
  variants[`${layout}-trying-leo`] = {
    note: `${LAYOUTS[layout]}; after Try Leo's setup: the trial bar offers Keep or Revert.`,
    props: { layout, on: [], trying: "leo" },
  };
  variants[`${layout}-leo`] = {
    note: `${LAYOUTS[layout]}; Leo's own: every customization on (on for him by default).`,
    props: { layout, on: LEO },
  };
}

export default componentEntry<Props>({
  id: "pages.customize-studio",
  title: "Customization paradigm (proposal)",
  area: "Settings",
  height: 760,
  widths: { narrow: 720, normal: 980, wide: 1280 },
  covers: ["pages/customize/CustomizeStudio.tsx#CustomizeStudio"],
  load,
  styles: async () => {
    await import("../settings/page.css");
    return import("./customizeStudio.css");
  },
  variants,
});
