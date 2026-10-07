// l10n-allow-file: gallery fixtures, not shipped UI.
import { bridgePageEntry, type BridgePageVariant } from "../../gallery/format";
import type { WireListing } from "./wire";
function fixture(count: number): BridgePageVariant {
  const apps: WireListing[] = Array.from({ length: count }, (_, i) => ({
    app: `sample/app-${i}`,
    name:
      count > 4
        ? `Sample extension ${i + 1} with a very long descriptive name`
        : ["Notes", "Terminal tools", "Project explorer", "Task board"][i]!,
    summary: "A public sample extension for organizing project work. ".repeat(count > 4 ? 8 : 1),
    publisher: "Sample publisher",
    tier: i % 2 === 0 ? "verified" : "unverified",
    categories: ["Developer tools"],
    version: "1.2.0",
    icon: null,
    hide_only: false,
    install: null,
  }));
  return {
    streams: ["cmux.apps.watch"],
    replies: {
      "cmux.apps.catalog.list": { listings: apps, revision: 1, next_cursor: null },
      "cmux.apps.installed.list": { apps: [], revision: 1 },
    },
  };
}
export default bridgePageEntry({
  id: "pages.apps",
  title: "Apps",
  area: "Pages",
  page: "apps",
  covers: ["page:cmux.apps", "pages/apps/AppsPage.tsx", "pages/apps/parts.tsx"],
  variants: {
    empty: fixture(0),
    loaded: fixture(4),
    "long-content": fixture(40),
    error: {
      ...fixture(0),
      failures: {
        "cmux.apps.catalog.list": { code: "cmux.page.failed", message: "Sample owner is unavailable. Try again." },
      },
    },
    loading: { ...fixture(0), pending: ["cmux.apps.catalog.list"] },
  },
});
