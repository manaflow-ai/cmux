// The Community tab: the store against the owner's `source: "community"` answers (a sample
// registry, an empty one, an unreachable one, an owner that refuses or ignores the source), and
// the view's list, empty state, README page and install actions.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import { AppsPage } from "./AppsPage";
import { CommunityStore, communityRow, parseCommunityRoute, type CommunitySnapshot } from "./community";
import { CommunityMockProvider, sampleCommunity, type CommunityMockData } from "./communityMock";
import { CommunityView } from "./CommunityView";
import generated from "./generated/strings.json";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore } from "./store";
import { AppsOps } from "./types";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
};

const FOCUS = "github.com/sample-author/focus-timer";

async function open(data: CommunityMockData, hash = "#/community") {
  const client = new CommunityMockProvider(new MockAppsProvider(), data);
  const apps = new AppsStore(client, hash);
  const community = new CommunityStore(client, (app) => apps.install(app), hash);
  await community.start();
  return { client, apps, community };
}

function view(community: CommunityStore, snap: CommunitySnapshot = community.getSnapshot()): string {
  return renderToStaticMarkup(<CommunityView snap={snap} store={community} strings={strings} />);
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("an empty registry shows the calm empty state with the website link", async () => {
  const { community } = await open({ items: [] });
  const html = view(community);
  expect(html).toContain('data-community-state="empty"');
  expect(html).toContain(en["store.community.empty.title"]!);
  expect(html).toContain('href="https://cmux.com/extensions"');
  expect(html).not.toContain('role="alert"');
});

test("an unreachable registry, an owner that refuses the source, and one that ignores it all show the empty state", async () => {
  for (const data of [
    { items: [], error: "registry: route.not_found" },
    { items: [], refuse: true },
  ]) {
    const { community } = await open(data);
    expect(community.getSnapshot().unavailable).toBe(true);
    expect(view(community)).toContain('data-community-state="empty"');
  }
  // An older owner answers its own listings for any catalog.list: none of them is a community row.
  const apps = new MockAppsProvider();
  const community = new CommunityStore(apps, async () => {}, "#/community");
  await community.start();
  expect(community.getSnapshot().rows).toEqual([]);
  expect(community.getSnapshot().unavailable).toBe(true);
  expect(view(community)).toContain('data-community-state="empty"');
  expect(view(community)).not.toContain("apps-community-row");
});

test("the list asks the community source and shows each row's name, author, downloads and last updated date", async () => {
  const { client, community } = await open(sampleCommunity());
  expect(client.calls[0]).toEqual({
    op: AppsOps.catalogList,
    params: { source: "community", sort: "featured", limit: 100 },
  });
  const html = view(community);
  expect(html).toContain(`data-community-row="${FOCUS}"`);
  expect(html).toContain("Focus Timer");
  expect(html).toContain("A pomodoro timer in the sidebar");
  expect(html).toContain("sample-author");
  expect(html).toContain("12,400 downloads");
  expect(html).toContain("Updated Nov 12, 2026");
  expect(html).toContain(en["store.community.kind.extension"]!);
  // An installed row shows its state, not Install.
  expect(html).toMatch(/data-community-row="github.com\/sample-author\/teal-twin".*?Installed/);
});

test("every registry kind shows: Themes and Snippets filters join Extensions and Setups, and no row is dropped", async () => {
  const { community } = await open(sampleCommunity());
  const snap = community.getSnapshot();
  expect(snap.kinds).toEqual(["extension", "setup", "theme", "snippet"]);
  expect(snap.rows.map((row) => row.kind).sort()).toEqual([
    "extension",
    "extension",
    "setup",
    "setup",
    "snippet",
    "theme",
  ]);
  const html = view(community);
  for (const key of ["extensions", "setups", "themes", "snippets"])
    expect(html).toContain(en[`store.community.kind.${key}`]!);
  expect(html).toMatch(/data-community-row="github.com\/sample-author\/teal-twin".*?>Theme</);
  expect(html).toMatch(/data-community-row="github.com\/example-org\/git-log-graph".*?>Snippet</);
  // A kind filter keeps every chip, so the person can switch straight to another kind.
  community.setKind("theme");
  await settle();
  expect(community.getSnapshot().rows.map((row) => row.name)).toEqual(["Teal Twin"]);
  expect(community.getSnapshot().kinds).toEqual(["extension", "setup", "theme", "snippet"]);
  // A registry with no themes or snippets offers only the two filters that always show.
  const plain = await open({ items: sampleCommunity().items.filter((row) => row.kind === "extension") });
  expect(plain.community.getSnapshot().kinds).toEqual(["extension", "setup"]);
});

test("search, kind and sort go to the owner", async () => {
  const { client, community } = await open(sampleCommunity());
  community.setKind("setup");
  await settle();
  expect(community.getSnapshot().rows.map((row) => row.kind)).toEqual(["setup", "setup"]);
  community.setSort("downloads");
  community.setQuery("writing");
  await settle();
  expect(client.calls.at(-1)?.params).toEqual({
    source: "community",
    sort: "downloads",
    limit: 100,
    query: "writing",
    kind: "setup",
  });
  expect(community.getSnapshot().rows.map((row) => row.name)).toEqual(["Writing Desk"]);
  community.setQuery("nothing like this");
  await settle();
  expect(view(community)).toContain('data-community-state="no-matches"');
});

test("Install calls apps.install with the row's install_app through the page's install path", async () => {
  const { client, community } = await open(sampleCommunity());
  const row = community.getSnapshot().rows.find((item) => item.ref === FOCUS)!;
  expect(view(community)).toContain(`data-install-app="${row.install_app}"`);
  await community.install(row.install_app);
  const install = client.calls.find((call) => call.op === AppsOps.install);
  expect(install).toEqual({ op: AppsOps.install, params: { app: row.install_app, grant_optional: false } });
  expect(row.install_app).toBe(`${FOCUS}@${row.commit}`);
  expect(community.getSnapshot().rows.find((item) => item.ref === FOCUS)?.installed).toBe(true);
});

test("an item from another device offers Install on This Mac, which installs its install_app", async () => {
  const { client, community } = await open(sampleCommunity());
  const [elsewhere] = community.getSnapshot().elsewhere;
  expect(elsewhere?.action).toBe("install_on_this_mac");
  const html = view(community);
  expect(html).toContain(en["store.community.onOtherDevices"]!);
  expect(html).toContain(en["store.community.installOnThisMac"]!);
  expect(html).toContain(`data-install-app="${elsewhere!.install_app}"`);
  await community.install(elsewhere!.install_app);
  expect(client.calls.filter((call) => call.op === AppsOps.install).map((call) => call.params.app)).toEqual([
    elsewhere!.install_app,
  ]);
  expect(community.getSnapshot().elsewhere).toEqual([]);
});

test("an install in flight disables its button until the host answers", async () => {
  const { community } = await open({ ...sampleCommunity(), holdInstall: true });
  const row = community.getSnapshot().rows.find((item) => item.ref === FOCUS)!;
  void community.install(row.install_app);
  await settle();
  expect(view(community)).toContain(`data-install-app="${row.install_app}" disabled="" aria-busy="true"`);
  // The other rows' buttons stay live.
  expect(view(community)).toContain('data-install-app="github.com/example-org/standup-notes@');
  expect(view(community)).not.toMatch(/standup-notes@[0-9a-f]+" disabled/);
});

test("a row's page renders its README as elements, with the facts beside it", async () => {
  const { client, community } = await open(sampleCommunity(), `#/community?ref=${FOCUS}`);
  expect(client.calls).toContainEqual({ op: AppsOps.catalogGet, params: { source: "community", ref: FOCUS } });
  const html = view(community);
  expect(html).toContain(`data-community-detail="${FOCUS}"`);
  expect(html).toContain(en["store.community.readme"]!);
  expect(html).toContain("<h4>Features</h4>");
  expect(html).toContain("<code>focusTimer.minutes</code>");
  expect(html).toContain(en["store.community.license"]!);
  expect(html).toContain("MIT");
  expect(html).toContain('href="https://github.com/sample-author/focus-timer"');
});

test("apps-changed re-reads an open Community tab", async () => {
  const { client, community } = await open({ items: [] });
  expect(community.getSnapshot().rows).toEqual([]);
  client.data = sampleCommunity();
  client.changed();
  await settle();
  expect(community.getSnapshot().rows.length).toBe(6);
});

test("a hidden Community tab reads nothing until it is opened", async () => {
  const { client, community } = await open(sampleCommunity(), "#/discover");
  expect(client.calls.filter((call) => call.params.source === "community")).toEqual([]);
  community.setActive(true);
  await settle();
  expect(community.getSnapshot().rows.length).toBe(6);
});

test("the toolbar has a Community tab between Discover and Installed", () => {
  const apps = new AppsStore(null);
  const community = new CommunityStore(null, async () => {}, "#/community");
  const html = renderToStaticMarkup(<AppsPage store={apps} strings={strings} community={community} />);
  const tabs = [...html.matchAll(/role="tab"[^>]*>([^<]+)</g)].map((match) => match[1]);
  expect(tabs).toEqual([en["store.tab.discover"], en["store.tab.community"], en["store.tab.installed"]]);
  // Without a Community store the page keeps its two tabs.
  const plain = renderToStaticMarkup(<AppsPage store={apps} strings={strings} />);
  expect([...plain.matchAll(/role="tab"/g)].length).toBe(2);
});

test("routes and rows parse defensively", () => {
  expect(parseCommunityRoute("#/community?ref=github.com/a/b")).toEqual({ active: true, ref: "github.com/a/b" });
  expect(parseCommunityRoute("#/discover")).toEqual({ active: false, ref: undefined });
  expect(communityRow({ app: "cmux/cloud", name: "Cloud" })).toBeUndefined();
  expect(communityRow({ source: "community", ref: "github.com/a/b", name: "B" })).toBeUndefined();
});
