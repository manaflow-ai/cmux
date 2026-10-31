// l10n-allow-file: gallery fixtures (public-safe sample app data), not shipped UI.
import { appsPageEntry, type AppsPageVariant } from "../../gallery/format";
import { sampleApps, sampleLocalApp, sampleRegistry } from "./mockProvider";
import type { RegistryMe } from "./types";

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

// The community registry (custom-panes-DESIGN.md 6.4). A person who is not a reviewer sees no Review tab.
const person: RegistryMe = { signedIn: true, user: "user_sample", reviewer: false, publishers: ["sample-studio"] };
const community = { ...structuredClone(base), registry: sampleRegistry(person) };
const communityInstalled = { ...structuredClone(base), registry: sampleRegistry(person) };
communityInstalled.details["sample-studio/workspace-board"] = {
  ...structuredClone(communityInstalled.registry.bundles["sample-studio/workspace-board"]!),
  latest_version: "0.1.0",
  installed: true,
};
communityInstalled.installed["sample-studio/workspace-board"] = {
  id: "sample-studio/workspace-board",
  name: "Workspace Board",
  version: "0.1.0",
  enabled: true,
  hidden: false,
  sandboxed: true,
  source: "user",
  tier: "unverified",
};
const publishing = (me: RegistryMe = person) => {
  const data = { ...structuredClone(base), registry: sampleRegistry(me) };
  data.installed["local/notes-pane"] = sampleLocalApp();
  return data;
};
const reviewing = { ...structuredClone(base), registry: sampleRegistry() };

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
    "pages/apps/Community.tsx",
    "pages/apps/Submissions.tsx",
    "pages/apps/ReviewView.tsx",
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
    community: {
      note: "Discover's Community section: approved registry apps with Get, under the catalog.",
      hash: "#/discover?layout=grid",
      data: community,
    },
    "community-installed": {
      note: "A community app already installed at an older version offers its newer approved version.",
      hash: "#/discover?layout=grid",
      data: communityInstalled,
    },
    submissions: {
      note: "Installed with a local app's Submit for Review and My Submissions: in review, approved, rejected with a reason.",
      hash: "#/installed",
      data: publishing(),
    },
    "submit-form": {
      note: "The Submit for Review form with the publisher prefilled from the person's first publisher.",
      action: "submit",
      hash: "#/installed",
      data: publishing(),
    },
    "submit-signed-out": {
      note: "Signed out: Submit for Review shows the sign-in hint instead of the form.",
      action: "submit",
      hash: "#/installed",
      data: publishing({ signedIn: false, user: null, reviewer: false, publishers: [] }),
    },
    review: {
      note: "The reviewer's Review tab: the queue, the manifest summary, files, a file open as text, Approve and Reject.",
      action: "review-file",
      hash: "#/review",
      data: reviewing,
    },
    "detail-error": {
      note: "The selected app detail fails once, then can be retried without losing selection.",
      detailError: { code: "cmux.apps.backend_unavailable", message: "The app details are temporarily unavailable." },
      hash: "#/discover?layout=split&app=cmux.coderouter",
      data: base,
    },
  },
});
