// l10n-allow-file: gallery fixtures (public-safe sample app data), not shipped UI.
// Use as New Tab: two installed apps that draw on the New Tab page (`cmux.newtab/1`). Launcher is
// the one New Tab shows (`tabs.newTabApp`): On New Tab and Stop Using as New Tab; Start Page offers
// Use as New Tab. The apps are samples, never a listed example.
import { appsPageEntry } from "../../gallery/format";
import { sampleApps } from "./mockProvider";

const data = sampleApps();
const template = data.details["acme.caffeinate"]!;
for (const [id, name] of [
  ["sample/launcher", "Launcher"],
  ["sample/start-page", "Start Page"],
] as const) {
  data.details[id] = {
    ...structuredClone(template),
    id,
    name,
    description: "Draws above the composer on every New Tab.",
    publisher: "sample",
    categories: ["productivity"],
    installed: true,
    new_tab: true,
  };
  data.installed[id] = {
    id,
    name,
    version: "2.0.1",
    enabled: true,
    hidden: false,
    sandboxed: false,
    source: "user",
    tier: "verified",
    new_tab: true,
  };
}
data.newTabApp = "sample/launcher";

export default appsPageEntry({
  id: "pages.apps-newtab",
  title: "App Store: Use as New Tab",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: ["pages/apps/UseAsNewTab.tsx"],
  variants: {
    installed: {
      note: "Installed apps with a New Tab view: the current one says On New Tab and offers Stop Using as New Tab; the other offers Use as New Tab.",
      hash: "#/installed",
      data,
    },
    discover: {
      note: "The same apps on their Discover cards.",
      hash: "#/discover?layout=grid",
      data,
    },
  },
});
