// The listing page and Discover's store rules (AppDetailView.tsx, AppsPage.tsx, model.ts): the
// owner's tagline, screenshots and places map from the wire; permissions show in plain words and
// never as the raw scope id; Discover leaves out a listing with no description or one the host
// failed to load; a deep link to an app the store does not list lands on Discover.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import { pageError } from "../shared/pageClient";
import { AppDetailView } from "./AppDetailView";
import { AppsPage } from "./AppsPage";
import generated from "./generated/strings.json";
import { GrantsPanel } from "./GrantsPanel";
import { PermissionList } from "./items";
import { filterApps, parseBrowseStyle, parseListingStyle, parseRoute, scopeHeading } from "./model";
import { manyStoreApps, MockAppsProvider, storeApps } from "./mockProvider";
import { AppsStore, type AppsSnapshot } from "./store";
import { AppsOps, type CatalogApp, type ScopeRequest } from "./types";
import { fromDetail, fromListing, type WireDetail } from "./wire";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
};

const wire: WireDetail = {
  app: "cmux/cloud",
  name: "Cloud",
  summary: "Create, start and pause your Cloud machines.",
  tagline: "Start, pause and connect to your Cloud machines",
  publisher: "cmux",
  tier: "first-party",
  version: "1.4.0",
  icon: { symbol: "cloud" },
  categories: ["cloud"],
  hide_only: true,
  install: null,
  scopes: [],
  screenshots: ["screenshots/1.png", "screenshots/2.png"],
  contributes: [
    { kind: "pane", title: "Cloud" },
    { kind: "command", title: "New Cloud Machine" },
  ],
};

test("the wire's tagline, screenshots and places map onto the listing, tolerant of an older owner", () => {
  const detail = fromDetail(wire);
  expect(detail.tagline).toBe("Start, pause and connect to your Cloud machines");
  expect(detail.screenshots).toEqual(["screenshots/1.png", "screenshots/2.png"]);
  expect(detail.contributes).toEqual([
    { kind: "pane", title: "Cloud" },
    { kind: "command", title: "New Cloud Machine" },
  ]);
  // An owner older than the fields sends none of them: no tagline, no screenshots, no places.
  const { tagline: _t, screenshots: _s, contributes: _c, ...old } = wire;
  const plain = fromDetail(old);
  expect(plain.tagline).toBeUndefined();
  expect(plain.screenshots).toEqual([]);
  expect(plain.contributes).toBeUndefined();
  // A blank or null tagline is no tagline; a malformed screenshot list keeps only its paths.
  expect(fromListing({ ...wire, tagline: "  " }).tagline).toBeUndefined();
  expect(fromListing({ ...wire, tagline: null }).tagline).toBeUndefined();
  expect(fromDetail({ ...wire, screenshots: ["a.png", 7, null, ""] as unknown as string[] }).screenshots).toEqual([
    "a.png",
  ]);
  expect(fromDetail({ ...wire, screenshots: "a.png" as unknown as string[] }).screenshots).toEqual([]);
});

test("a listing the host failed to load is marked failed", () => {
  const state = {
    installed: true,
    enabled: true,
    hidden: false,
    sandboxed: false,
    source: "default" as const,
    version: "1.0.0",
    update: null,
  };
  expect(fromListing({ ...wire, install: { ...state, failure: "The app failed to start." } }).failed).toBe(true);
  expect(fromListing({ ...wire, install: { ...state, failure: null } }).failed).toBe(false);
  expect(fromListing(wire).failed).toBe(false);
});

test("the listing and browse styles come from the route, defaulting to carousel and hero", () => {
  expect(parseListingStyle(undefined)).toBe("carousel");
  expect(parseListingStyle("bogus")).toBe("carousel");
  expect(parseListingStyle("stacked")).toBe("stacked");
  expect(parseBrowseStyle(null)).toBe("hero");
  expect(parseBrowseStyle("list")).toBe("list");
  const route = parseRoute("#/discover?listing=compact&browse=pair");
  expect(route.listing).toBe("compact");
  expect(route.browse).toBe("pair");
});

const scopes: ScopeRequest[] = [
  { scope: "cloud:write", reason: "Start and pause your machines.", risk: "sensitive", optional: false },
  { scope: "cloud:read", reason: "See your machines.", risk: "standard", optional: false },
  { scope: "terminal:backend", reason: "Open terminals on your machines.", risk: "restricted", optional: true },
  { scope: "mystery:thing", reason: "Something only this app does.", risk: "standard", optional: false },
];

test("permissions show a plain heading and the reason, optional ones marked, never the scope id", () => {
  const html = renderToStaticMarkup(<PermissionList scopes={scopes} strings={strings} />);
  expect(html).toContain(en["store.scope.cloud"]!);
  expect(html).toContain(en["store.scope.terminal"]!);
  expect(html).toContain("See your machines.");
  expect(html).toContain("Something only this app does.");
  expect(html).toContain(en["store.detail.optional"]!);
  for (const { scope } of scopes) expect(html).not.toContain(scope);
  expect(html).not.toContain("<code");
  // An unknown namespace has no heading, never its raw name.
  expect(scopeHeading("mystery:thing", strings.t)).toBeUndefined();
  expect(scopeHeading("__proto__:x", strings.t)).toBeUndefined();
  // Two Cloud permissions share one heading.
  expect(html.split(en["store.scope.cloud"]!).length - 1).toBe(1);
  expect(renderToStaticMarkup(<PermissionList scopes={[]} strings={strings} />)).toContain(
    en["store.detail.noPermissions"]!,
  );
});

test("an installed app's grant switches use the same plain words, never the scope id", () => {
  const html = renderToStaticMarkup(
    <GrantsPanel
      grants={{ app: "cmux/cloud", sandboxed: false, scopes: scopes.map((row) => ({ ...row, granted: true })) }}
      store={{} as AppsStore}
      strings={strings}
    />,
  );
  expect(html).toContain(en["store.scope.cloud"]!);
  expect(html).toContain("Start and pause your machines.");
  for (const { scope } of scopes) expect(html).not.toContain(scope);
});

test("the listing page shows the tagline, the meta line, Shows up in and its facts, and no scope id", async () => {
  const store = new AppsStore(new MockAppsProvider(storeApps()), "#/discover?layout=grid&app=cmux/cloud");
  await store.start();
  const snap = store.getSnapshot();
  store.stop();
  expect(snap.detail?.id).toBe("cmux/cloud");
  const html = renderToStaticMarkup(<AppDetailView snap={snap} store={store} strings={strings} showsBack />);
  expect(html).toContain('data-listing-style="carousel"');
  expect(html).toContain("Start, pause and connect to your Cloud machines");
  expect(html).toContain(en["store.detail.free"]!);
  expect(html).toContain(en["store.detail.showsUpIn"]!);
  expect(html).toContain(`<dt>${en["store.contribution.pane"]}</dt>`);
  expect(html).toContain(en["store.detail.information"]!);
  expect(html).toContain(en["store.scope.cloud"]!);
  for (const { scope } of snap.detail!.scopes) expect(html).not.toContain(scope);
});

test("the listing's screenshots load through asset.get and show in the carousel", async () => {
  const provider = new MockAppsProvider(storeApps());
  const store = new AppsStore(provider, "#/discover?layout=grid&app=cmux/coderouter");
  await store.start();
  await until(() => (store.getSnapshot().detail?.screenshotImages?.length ?? 0) > 0);
  const snap = store.getSnapshot();
  store.stop();
  expect(snap.detail?.screenshotImages?.length).toBe(2);
  expect(snap.detail?.screenshotImages?.every((url) => url.startsWith("data:image/"))).toBe(true);
  const asked = provider.calls.filter((call) => call.op === AppsOps.assetGet && call.params.app === "cmux/coderouter");
  expect(asked.map((call) => call.params.path)).toEqual(
    expect.arrayContaining(["screenshots/1.svg", "screenshots/2.svg"]),
  );
  const html = renderToStaticMarkup(<AppDetailView snap={snap} store={store} strings={strings} />);
  expect(html.match(/class="apps-carousel-thumb[ "]/g)?.length).toBe(2);
});

test("Discover leaves out a listing with no description and one that failed to load", async () => {
  const app = (overrides: Partial<CatalogApp>): CatalogApp => ({
    id: "x",
    name: "X",
    description: "Does a thing.",
    publisher: "cmux",
    publisher_verified: true,
    tier: "first-party",
    categories: ["productivity"],
    latest_version: "1.0.0",
    install_count: 0,
    installed: false,
    ...overrides,
  });
  const apps = [app({ id: "ok" }), app({ id: "blank", description: " " }), app({ id: "broken", failed: true })];
  expect(filterApps(apps, "", undefined).map((row) => row.id)).toEqual(["ok"]);
  // The developers' Examples shelf shows what it has.
  const examples = apps.map((row) => ({ ...row, shelf: "example" as const }));
  expect(filterApps(examples, "", undefined, "example").length).toBe(3);

  const store = new AppsStore(new MockAppsProvider(manyStoreApps()), "#/discover?layout=grid");
  await store.start();
  const ids = store.getSnapshot().visible.map((row) => row.id);
  const html = renderToStaticMarkup(<AppsPage store={store} strings={strings} />);
  store.stop();
  expect(ids).toContain("cmux/cloud");
  expect(ids).not.toContain("cmux/untitled");
  expect(ids).not.toContain("cmux/broken");
  expect(html).not.toContain("Untitled Widget");
  expect(html).not.toContain("Broken Widget");
});

test("Discover's hero features the first-party apps; a dozen get category shelves", async () => {
  const two = new AppsStore(new MockAppsProvider(storeApps()), "#/discover?layout=grid");
  await two.start();
  const small = renderToStaticMarkup(<AppsPage store={two} strings={strings} />);
  two.stop();
  expect(small.match(/class="apps-hero"/g)?.length).toBe(2);
  expect(small).not.toContain("apps-cloud-feature");

  const many = new AppsStore(new MockAppsProvider(manyStoreApps()), "#/discover?layout=grid");
  await many.start();
  const big = renderToStaticMarkup(<AppsPage store={many} strings={strings} />);
  many.stop();
  expect(big.match(/class="apps-hero"/g)?.length).toBe(1);
  expect(big).toContain(`>${en["store.category.productivity"]}</h3>`);
  expect(big).toContain(`>${en["store.browse.more"]}</h3>`);
});

test("a deep link to an app the store does not list lands on Discover with a quiet note", async () => {
  const provider = new MockAppsProvider(storeApps());
  const store = new AppsStore(provider, "#/discover?layout=grid&app=cmux/running-agents");
  await store.start();
  const snap: AppsSnapshot = store.getSnapshot();
  const html = renderToStaticMarkup(<AppsPage store={store} strings={strings} />);
  expect(snap.selection).toBeUndefined();
  expect(snap.detailStatus).toBe("idle");
  expect(snap.notice).toBe("notInStore");
  expect(html).toContain(en["store.notice.notInStore"]!.replace("'", "&#x27;"));
  expect(html).not.toContain(en["store.stillLoading"]!);
  expect(html).not.toContain(en["store.detail.notFound"]!);
  expect(html).not.toContain('role="alert"');
  expect(html).toContain("apps-hero");
  // The host opening another unlisted app later does the same; the next navigation clears the note.
  await store.select("cmux/gone");
  expect(store.getSnapshot().selection).toBeUndefined();
  store.setCategory("cloud");
  expect(store.getSnapshot().notice).toBeUndefined();
  // An owner that answers not_found for a listed app also lands on Discover.
  provider.failNext(AppsOps.catalogGet, pageError("cmux.apps.not_found", "cmux/cloud"));
  await store.select("cmux/cloud");
  expect(store.getSnapshot().selection).toBeUndefined();
  expect(store.getSnapshot().notice).toBe("notInStore");
  store.stop();
});

async function until(ready: () => boolean): Promise<void> {
  for (let tries = 0; tries < 200 && !ready(); tries += 1) await Promise.resolve();
}
