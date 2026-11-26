// l10n-allow-file: gallery fixtures (public-safe sample app data), not shipped UI.
import { appsPageEntry, type AppsPageVariant } from "../../gallery/format";
import { sampleApps, manyStoreApps, storeApps } from "./mockProvider";

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
  tagline: "Run a tiny web server on your own machine or Cloud and open it in a tab",
  description:
    "Installing runs a small web server on your cmux Cloud machine or on a machine you host yourself, then opens it in a tab. The page shows the request headers the server receives, so you can see everything is connected.",
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

// An app installed from a git repo: its page links the repo at the pinned commit.
const fromGit = structuredClone(base);
fromGit.details["sample-org/standup"] = {
  ...structuredClone(template),
  id: "sample-org/standup",
  name: "Standup",
  description: "A public-safe sample app installed from a git repo subdirectory, pinned to a tagged commit.",
  publisher: "sample-org",
  publisher_verified: false,
  tier: "unverified",
  repository: "https://github.com/sample-org/cmux-apps",
  path: "apps/standup",
  commit: "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345",
  tag: "v1.2.0",
};

// The curated store (Leo, 2026-11-16: "idk if we want to ship THOSE as standard apps"): Discover
// lists only the first-party apps cmux ships (Cloud, CodeRouter); the SDK examples are on the
// Examples shelf, offered to developers; `cmux ext dev` apps show only under Installed.
const curatedTemplate = structuredClone(template);
const app = (
  id: string,
  name: string,
  tagline: string,
  description: string,
  shelf: "store" | "example" | "local",
  categories: string[],
  symbol: string,
): (typeof base.details)[string] => ({
  ...structuredClone(curatedTemplate),
  id,
  name,
  tagline,
  description,
  shelf,
  categories,
  icon: { symbol },
  publisher: id.split("/")[0]!,
  publisher_verified: shelf === "store",
  tier: shelf === "store" ? "first-party" : "unverified",
  latest_version: "1.0.0",
  versions: [{ version: "1.0.0", engines: "cmux ^2.0" }],
  installed: shelf === "local",
  scopes: [],
});
const store = storeApps();
const curatedApps = [
  ...Object.values(store.details),
  app(
    "manaflow-ai/quick-links",
    "Quick Links",
    "Your favorite links in the sidebar, one click to open",
    "Keep the links you use most in the sidebar and in their own tab. Click one to open it in a browser tab, and edit the list in Settings.",
    "example",
    ["sidebar", "productivity"],
    "link",
  ),
  app(
    "manaflow-ai/standup",
    "Standup",
    "Jot what you did, read it back at standup, then clear it",
    "Jot down what you did as you go, list it all at standup, and clear it when you're done. Everything runs from the command palette or the cmux command line.",
    "example",
    ["productivity"],
    "checklist",
  ),
  app(
    "manaflow-ai/cmux-docs",
    "cmux Docs",
    "The cmux docs one click away in your sidebar",
    "The cmux docs, pinned to your sidebar. Click to read them in a tab right next to your work.",
    "example",
    ["developer-tools"],
    "book",
  ),
  app(
    "manaflow-ai/hello-deploy",
    "Hello Deploy",
    "Run a tiny web server on your own machine or Cloud and open it in a tab",
    "Installing runs a small web server on your cmux Cloud machine or on a machine you host yourself, then opens it in a tab.",
    "example",
    ["developer-tools", "cloud"],
    "server.rack",
  ),
  app(
    "local/changes",
    "Changes",
    "Your open pull requests, live, in the sidebar",
    "Your open pull requests, live, in the sidebar.",
    "local",
    ["git"],
    "arrow.triangle.pull",
  ),
  app("local/clock", "Clock", "A clock on New Tab", "A clock on the New Tab page.", "local", ["fun"], "clock"),
];
const curated = {
  assets: store.assets,
  details: Object.fromEntries(curatedApps.map((detail) => [detail.id, detail])),
  installed: Object.fromEntries(
    curatedApps
      .filter((detail) => detail.shelf === "local")
      .map((detail) => [
        detail.id,
        {
          id: detail.id,
          name: detail.name,
          version: "1.0.0",
          enabled: true,
          hidden: false,
          sandboxed: false,
          source: "local" as const,
          tier: "unverified" as const,
          icon: detail.icon,
        },
      ]),
  ),
  grants: {},
};
// The store with a dozen apps (the widget apps from the widgets lane), one listing with no
// description and one the host failed to load: Discover shows neither.
const many12 = manyStoreApps();
// Cloud installed (a first-party app: Show/Hide, Open), with its permissions as switches.
const cloudInstalled = structuredClone(store);
cloudInstalled.details["cmux/cloud"]!.installed = true;
cloudInstalled.installed["cmux/cloud"] = {
  id: "cmux/cloud",
  name: "Cloud",
  version: "1.4.0",
  enabled: true,
  hidden: false,
  sandboxed: false,
  source: "default",
  tier: "first-party",
};
cloudInstalled.grants["cmux/cloud"] = {
  app: "cmux/cloud",
  sandboxed: false,
  scopes: cloudInstalled.details["cmux/cloud"]!.scopes.map((scope) => ({ ...scope, granted: !scope.optional })),
};

// A developer (developer mode on, or a `cmux ext dev` app): the owner offers Examples.
const curatedDeveloper = { ...structuredClone(curated), examples: true };

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
    "pages/apps/SourceLink.tsx",
  ],
  variants: {
    "browse-hero-rows": {
      note: "Chosen Discover (browse=hero, the default): Cloud and CodeRouter each as a hero with a screenshot; a small store needs no shelves.",
      hash: "#/discover?layout=grid",
      data: store,
    },
    "browse-hero-rows-many": {
      note: "Chosen Discover with a dozen apps: Cloud as the hero, then a shelf per category with two or more apps, the rest under More apps. The untitled and the broken listing never show.",
      hash: "#/discover?layout=grid",
      data: many12,
    },
    "browse-grid-featured-pair": {
      note: "Variant (DEV, browse=pair): the Cloud banner, two featured cards side by side, then every app.",
      hash: "#/discover?layout=grid&browse=pair",
      data: store,
    },
    "browse-grid-featured-pair-many": {
      note: "Variant (DEV, browse=pair) with a dozen apps.",
      hash: "#/discover?layout=grid&browse=pair",
      data: many12,
    },
    "browse-raycast-list": {
      note: "Variant (DEV, browse=list, the Raycast Store): rows with icon, name, one line, category tags, publisher and the action.",
      hash: "#/discover?layout=grid&browse=list",
      data: store,
    },
    "browse-raycast-list-many": {
      note: "Variant (DEV, browse=list) with a dozen apps.",
      hash: "#/discover?layout=grid&browse=list",
      data: many12,
    },
    "listing-carousel-sidebar": {
      note: "Chosen listing (listing=carousel, the default): big icon, name, tagline, meta line and Install on the right; the screenshot carousel; Shows up in, Permissions and Information in a column on the right.",
      hash: "#/discover?layout=grid&app=cmux/coderouter",
      data: store,
    },
    "listing-carousel-sidebar-cloud": {
      note: "The chosen listing for Cloud: its own tab and palette commands under Shows up in; the optional terminal permission says Optional.",
      hash: "#/discover?layout=grid&app=cmux/cloud",
      data: store,
    },
    "listing-carousel-installed": {
      note: "The chosen listing once installed: Open and Hide; the permissions become switches in the main column, in the same plain words.",
      hash: "#/discover?layout=grid&app=cmux/cloud",
      data: cloudInstalled,
    },
    "listing-carousel-widget": {
      note: "The chosen listing for a widget app (Usage): one screenshot, Sidebar widget and New Tab places.",
      hash: "#/discover?layout=grid&app=cmux/usage",
      data: many12,
    },
    "listing-hero-stacked": {
      note: "Variant (DEV, listing=stacked, the iOS App Store): a screenshot strip, the description, then an Information grid of Shows up in, Permissions and the facts.",
      hash: "#/discover?layout=grid&listing=stacked&app=cmux/coderouter",
      data: store,
    },
    "listing-compact": {
      note: "Variant (DEV, listing=compact, the Raycast Store): one readable column, the facts after the description.",
      hash: "#/discover?layout=grid&listing=compact&app=cmux/coderouter",
      data: store,
    },
    "deep-link-not-in-store": {
      note: "A deep link to an app the store does not list (a sample that left Discover): Discover with one quiet line, never an error page.",
      hash: "#/discover?layout=grid&app=cmux/running-agents",
      data: store,
    },
    curated: {
      note: "Discover as everyone sees it: only cmux's first-party apps (Cloud, CodeRouter); no SDK examples, no cmux ext dev apps.",
      hash: "#/discover?layout=grid",
      data: curated,
    },
    "curated-examples-chip": {
      note: "Chosen: for a developer, an Examples toggle ends the category row; Discover itself is unchanged.",
      hash: "#/discover?layout=grid",
      data: curatedDeveloper,
    },
    "curated-examples-chip-on": {
      note: "The Examples toggle on: the SDK examples (Quick Links, Standup, cmux Docs, Hello Deploy), no Cloud banner.",
      hash: "#/discover?layout=grid&shelf=examples",
      data: curatedDeveloper,
    },
    "curated-examples-tab": {
      note: "Variant (DEV, examples=tab): Examples as a third toolbar tab between Discover and Installed.",
      hash: "#/discover?layout=grid&examples=tab&shelf=examples",
      data: curatedDeveloper,
    },
    "curated-examples-section": {
      note: "Variant (DEV, examples=section): the examples in their own section under the store's apps.",
      hash: "#/discover?layout=grid&examples=section",
      data: curatedDeveloper,
    },
    "curated-installed-local": {
      note: "Installed: cmux ext dev apps show here as Local (dev), never on Discover.",
      hash: "#/installed",
      data: curated,
    },
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
    "detail-git": {
      note: "An app installed from git: Repository links github.com/OWNER/REPO/PATH @ the short commit, pinned to that commit.",
      hash: "#/discover?layout=split&app=sample-org/standup",
      data: fromGit,
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
      note: "A deep link names an app that is no longer in the catalog: the split view shows Discover's list and the quiet note.",
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
