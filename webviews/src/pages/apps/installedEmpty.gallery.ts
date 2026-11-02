// l10n-allow-file: gallery fixture, not shipped UI.
import { appsPageEntry } from "../../gallery/format";
import { sampleApps } from "./mockProvider";

export default appsPageEntry({
  id: "pages.apps-installed-empty",
  title: "Installed apps — empty",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: ["pages/apps/InstalledView.tsx"],
  variants: {
    empty: {
      note: "No installed apps, with Discover still available in the toolbar.",
      hash: "#/installed",
      data: { ...sampleApps(), installed: {}, grants: {} },
    },
  },
});
