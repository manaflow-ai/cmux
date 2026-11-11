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

// Hello Deploy (install = deploy + pin): its listing names where it runs, and once installed its
// row shows the running instance. The machine is a sample name, never a fleet host.
const deployed = structuredClone(base);
deployed.details["manaflow-ai/hello-deploy"] = {
  ...structuredClone(template),
  id: "manaflow-ai/hello-deploy",
  name: "Hello Deploy",
  description:
    "Install = deploy + pin: runs a small web server on your cmux Cloud machine or on a machine you host yourself, and opens it as a pane in your workspace.",
  publisher: "manaflow-ai",
  publisher_verified: false,
  tier: "unverified",
  categories: ["developer-tools", "cloud"],
  icon: { symbol: "server.rack" },
  latest_version: "1.0.0",
  versions: [{ version: "1.0.0", engines: "cmux ^2.0" }],
  scopes: [],
  deploy: { targets: ["self-hosted", "cloud-vm"], tenancy: ["user"] },
};
const deployedInstalled = structuredClone(deployed);
deployedInstalled.details["manaflow-ai/hello-deploy"]!.installed = true;
deployedInstalled.installed["manaflow-ai/hello-deploy"] = {
  id: "manaflow-ai/hello-deploy",
  name: "Hello Deploy",
  version: "1.0.0",
  enabled: true,
  hidden: false,
  sandboxed: true,
  source: "user",
  tier: "unverified",
  instance: {
    id: "inst_sample",
    target: "self-hosted:ops@build-01.example.com",
    state: "running",
    url: "http://127.0.0.1:49153",
  },
};

// The store after the trim (extensibility-DESIGN.md section 7): Cloud and CodeRouter are its apps on
// day one, Home and the App Store ship but are never listed, and the Settings card closes Discover.
const coderouter = base.details["cmux.coderouter"]!;
const cloud: (typeof base.details)[string] = {
  ...structuredClone(coderouter),
  id: "cmux/cloud",
  name: "Cloud",
  description: "Machines, files and terminals on your own cloud machines.",
  categories: ["cloud", "developer-tools"],
  latest_version: "2.0.0",
  icon: { symbol: "cloud" },
  scopes: [
    {
      scope: "op:cmux.credential.relay",
      reason: "Sends each Cloud request through cmux.",
      risk: "sensitive",
      optional: false,
    },
  ],
  versions: [{ version: "2.0.0", engines: "^2.0" }],
};
const shippedOnly = {
  details: {
    "cmux/cloud": { ...cloud, installed: true },
    "cmux.coderouter": { ...structuredClone(coderouter), installed: true },
    // Shipped and installed, never listed (the owner's store_listing.rs; the mock mirrors it).
    "cmux/home": { ...structuredClone(coderouter), id: "cmux/home", name: "Home", installed: true },
    "cmux/app-store": structuredClone(base.details["cmux/app-store"]!),
  },
  installed: {
    "cmux/cloud": {
      id: "cmux/cloud",
      name: "Cloud",
      version: "2.0.0",
      enabled: true,
      hidden: false,
      sandboxed: false,
      source: "default",
      tier: "first-party",
    },
    "cmux.coderouter": {
      id: "cmux.coderouter",
      name: "CodeRouter",
      version: "0.4.0",
      enabled: true,
      hidden: true,
      sandboxed: false,
      source: "default",
      tier: "first-party",
    },
    "cmux/home": {
      id: "cmux/home",
      name: "Home",
      version: "1.0.0",
      enabled: true,
      hidden: false,
      sandboxed: false,
      source: "default",
      tier: "first-party",
    },
    "cmux/app-store": structuredClone(base.installed["cmux/app-store"]!),
  },
  grants: {},
} satisfies AppsPageVariant["data"];
const noneInstalled = {
  details: {
    "cmux/cloud": structuredClone(cloud),
    "cmux.coderouter": structuredClone(coderouter),
    "cmux/home": { ...structuredClone(coderouter), id: "cmux/home", name: "Home" },
  },
  installed: {},
  grants: {},
} satisfies AppsPageVariant["data"];

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
    "pages/apps/SettingsCard.tsx",
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
    "detail-deploy": {
      note: "A deployed app's listing: Runs on names the kinds of machine its server accepts.",
      hash: "#/discover?layout=split&app=manaflow-ai/hello-deploy",
      data: deployed,
    },
    "installed-deploy": {
      note: "Installed with a deployed app: its row says where the instance runs.",
      hash: "#/installed",
      data: deployedInstalled,
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
    "installed-empty": {
      note: "No installed apps: the Installed tab names the next step, with Discover still in the toolbar.",
      hash: "#/installed",
      data: { ...base, installed: {}, grants: {} },
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
    "trim-discover": {
      note: "After the trim: Discover lists the apps cmux ships (Cloud, CodeRouter), never Home or the App Store, and ends with the Settings card.",
      hash: "#/discover?layout=grid",
      data: shippedOnly,
    },
    "trim-installed": {
      note: "After the trim: Installed shows Cloud and the hidden CodeRouter; Home and the App Store are installed but never rows.",
      hash: "#/installed",
      data: shippedOnly,
    },
    "trim-none-installed": {
      note: "After the trim with nothing installed: the two listings offer Install, then the Settings card.",
      hash: "#/discover?layout=grid",
      data: noneInstalled,
    },
    "trim-settings-card": {
      note: "The Settings card in the narrow list column of split layout: its button wraps under the text.",
      hash: "#/discover?layout=split&app=cmux/cloud",
      data: shippedOnly,
    },
    "detail-error": {
      note: "The selected app detail fails once, then can be retried without losing selection.",
      detailError: { code: "cmux.apps.backend_unavailable", message: "The app details are temporarily unavailable." },
      hash: "#/discover?layout=split&app=cmux.coderouter",
      data: base,
    },
  },
});
