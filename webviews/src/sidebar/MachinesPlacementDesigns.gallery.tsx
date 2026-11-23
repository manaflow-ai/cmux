// l10n-allow-file: gallery fixtures, not shipped UI.
// Where the Machines page lives now that the right sidebar is gone (#41025). Picked: `tile`, the
// Machines item in the sidebar's top tiles that opens the page on top, off by default (Add to Sidebar or
// the App Store's "Machines in Sidebar"), and Machines in Cmd+Shift+P. design/machines-section.md says why.
import { componentEntry } from "../gallery/format";
import type { MachinesPlacementDesignsProps } from "./MachinesPlacementDesigns";

export default componentEntry<MachinesPlacementDesignsProps>({
  id: "sidebar.machines-placement",
  title: "Machines: where the page lives (picked: destination tile)",
  area: "Sidebar",
  covers: ["sidebar/MachinesPlacementDesigns.tsx"],
  height: 520,
  widths: { normal: 1100, wide: 1400 },
  keywords: ["machines", "devices", "remote", "joined", "new workspace", "destination", "tile"],
  load: () => import("./MachinesPlacementDesigns").then((module) => module.MachinesPlacementDesigns),
  styles: async () => {
    await import("../pages/shared/pageBase.css");
    await import("../pages/machines/styles.css");
  },
  variants: {
    tile: {
      note: "Picked. A Machines tile beside Home and App Store opens the page on top, the list in one column; studio-mini (a Mac signed in to this account) shows New Workspace. Off by default.",
      props: { placement: "tile" },
    },
    section: {
      note: "A collapsible Machines section above the workspaces. Every machine already heads its own workspaces below, so each name shows twice, and the section takes rows from the workspace list.",
      props: { placement: "section" },
    },
    "section-collapsed": {
      note: "The section folded: one more header that is always there, holding nothing.",
      props: { placement: "section", collapsed: true },
    },
    settings: {
      note: "Machines in Settings > Devices. New Workspace on a machine is daily work, not a setting; it sits two clicks deep in a window of its own.",
      props: { placement: "settings" },
    },
  },
});
