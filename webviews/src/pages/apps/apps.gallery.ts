// l10n-allow-file: gallery fixtures (public-safe sample app data), not shipped UI.
import { appsPageEntry, type AppsPageVariant } from "../../gallery/format";
import { sampleApps } from "./mockProvider";

const base = sampleApps();
const empty = { details: {}, installed: {}, grants: {} } satisfies AppsPageVariant["data"];
const many = structuredClone(base);
const template = many.details["acme.caffeinate"]!;
for (let index = 1; index <= 28; index += 1) {
  const id = `sample.tool-${String(index).padStart(2, "0")}`;
  many.details[id] = {
    ...structuredClone(template),
    id,
    name: `Workspace Helper ${String(index).padStart(2, "0")}`,
    description: `A public-safe sample app with a deliberately long description for scrolling (${index}).`,
    publisher: "Sample Publisher",
  };
}

export default appsPageEntry({
  id: "pages.apps",
  title: "App Store",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: [
    "page:cmux.apps",
    "pages/apps/AppsPage.tsx",
    "pages/apps/CloudFeature.tsx",
    "pages/apps/AppDetailView.tsx",
    "pages/apps/InstalledView.tsx",
    "pages/apps/UpdatesView.tsx",
    "pages/apps/GrantsPanel.tsx",
    "pages/apps/parts.tsx",
    "pages/apps/items.tsx",
  ],
  variants: {
    list: {
      note: "The discover grid with first-party, verified and unverified apps, under the featured Cloud banner.",
      hash: "#/discover?layout=grid",
      data: base,
    },
    "card-compact": {
      note: "The compact card style (DEV, card=compact): one line of description and the action.",
      hash: "#/discover?layout=grid&card=compact",
      data: base,
    },
    "card-artwork": {
      note: "The artwork card style (DEV, card=artwork): the icon leads on a tinted panel.",
      hash: "#/discover?layout=grid&card=artwork",
      data: base,
    },
    detail: {
      note: "A selected app detail page with permissions, versions and repository.",
      hash: "#/discover?layout=split&app=cmux.coderouter",
      data: base,
    },
    installing: {
      note: "Install confirmation in flight for a catalog app.",
      action: "install",
      hash: "#/discover?layout=grid",
      data: base,
    },
    "detail-installed": {
      note: "An installed app's page: screenshots, what it adds, permissions, settings and versions.",
      hash: "#/discover?layout=split&app=cmux.github-prs",
      data: base,
    },
    loading: {
      note: "The catalog is still loading.",
      mode: "loading",
      hash: "#/discover?layout=grid",
      data: base,
    },
    installed: {
      note: "Installed apps with an update, grants and log controls.",
      hash: "#/installed",
      data: base,
    },
    empty: {
      note: "An empty catalog and installed tab.",
      hash: "#/discover?layout=grid",
      data: empty,
    },
    "many-apps": {
      note: "Twenty-eight long-named listings for scrolling and narrow panes.",
      hash: "#/discover?layout=list",
      data: many,
    },
    error: {
      note: "The catalog owner returns a permission error.",
      mode: "error",
      error: { code: "cmux.apps.permission", message: "The catalog is unavailable to this workspace." },
      hash: "#/discover?layout=grid",
      data: base,
    },
    "not-found": {
      note: "A deep link names an app that is no longer in the catalog.",
      hash: "#/discover?layout=split&app=sample.missing",
      data: base,
    },
    "detail-error": {
      note: "The selected app detail fails once, then can be retried without losing selection.",
      detailError: { code: "cmux.apps.backend_unavailable", message: "The app details are temporarily unavailable." },
      hash: "#/discover?layout=split&app=cmux.coderouter",
      data: base,
    },
  },
});
