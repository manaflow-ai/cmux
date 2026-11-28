// The App Store's Features tab (Leo, 2026-10-21, ask-36ade8776b: "have that app store area as a sort
// of way to, like, toggle things on and off"): each built-in feature is a switch on its own setting.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import { AppsPage } from "./AppsPage";
import { featureGroups, FeaturesView } from "./FeaturesView";
import generated from "./generated/strings.json";
import { MockAppsProvider, sampleFeatures, storeApps } from "./mockProvider";
import { parseFeaturesStyle, parseRoute } from "./model";
import { AppsStore } from "./store";
import { AppsOps } from "./types";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
};

test("the toolbar has a Features tab between Discover and Installed", async () => {
  const store = new AppsStore(new MockAppsProvider(storeApps()), "#/features");
  await store.start();
  await store.loadFeatures();
  const html = renderToStaticMarkup(<AppsPage store={store} strings={strings} />);
  store.stop();
  const discover = html.indexOf(`>${en["store.tab.discover"]}</button>`);
  const features = html.indexOf(`>${en["store.tab.features"]}</button>`);
  const installed = html.indexOf(`>${en["store.tab.installed"]}</button>`);
  expect(discover).toBeGreaterThan(-1);
  expect(features).toBeGreaterThan(discover);
  expect(installed).toBeGreaterThan(features);
});

test("the route picks the tab and the DEV style", () => {
  expect(parseRoute("#/features").tab).toBe("features");
  expect(parseRoute("#/features?features=tiles").features).toBe("tiles");
  expect(parseFeaturesStyle("chips")).toBe("chips");
  expect(parseFeaturesStyle("nonsense")).toBe("list");
});

test("a switch writes the feature through apps.features.set and reads the list again", async () => {
  const provider = new MockAppsProvider(storeApps());
  const store = new AppsStore(provider, "#/features");
  await store.loadFeatures();
  expect(store.getSnapshot().features.find((row) => row.id === "chief.channels")?.on).toBe(false);
  await store.setFeature("chief.channels", true);
  const set = provider.calls.find((call) => call.op === AppsOps.featuresSet);
  expect(set?.params).toEqual({ id: "chief.channels", on: true });
  expect(typeof set?.key).toBe("string");
  expect(store.getSnapshot().features.find((row) => row.id === "chief.channels")?.on).toBe(true);
  expect(provider.calls.filter((call) => call.op === AppsOps.featuresList).length).toBe(2);
});

test("experiments.appStoreFeatures off (the default) lists nothing and hides the tab", async () => {
  const provider = new MockAppsProvider(storeApps());
  provider.featuresEnabled = false;
  const store = new AppsStore(provider, "#/features");
  await store.start();
  await store.loadFeatures();
  expect(store.getSnapshot().featuresEnabled).toBe(false);
  expect(store.getSnapshot().features).toEqual([]);
  const html = renderToStaticMarkup(<AppsPage store={store} strings={strings} />);
  store.stop();
  expect(html).not.toContain(`>${en["store.tab.features"]}</button>`);
  expect(html).toContain(`>${en["store.tab.discover"]}</button>`);
  provider.featuresEnabled = true;
  await store.loadFeatures();
  expect(store.getSnapshot().featuresEnabled).toBe(true);
  expect(store.getSnapshot().features.length).toBeGreaterThan(0);
});

test("a refused switch goes back to the setting's value", async () => {
  const provider = new MockAppsProvider(storeApps());
  const store = new AppsStore(provider, "#/features");
  await store.loadFeatures();
  await store.setFeature("browser.bookmarksBar", true);
  expect(store.getSnapshot().features.find((row) => row.id === "browser.bookmarksBar")?.on).toBe(false);
});

test("groups keep the daemon's order and the search filters rows", () => {
  const groups = featureGroups(sampleFeatures());
  expect(groups.map(([group]) => group)).toEqual([
    "Backgrounds",
    "Chief",
    "Music",
    "Editor",
    "Browser",
    "Labs",
    "Experiments",
  ]);
  expect(featureGroups(sampleFeatures(), "pet").flatMap(([, rows]) => rows.map((row) => row.id))).toEqual([
    "chief.pet",
  ]);
});

for (const style of ["list", "tiles", "chips"] as const) {
  test(`the ${style} style draws one switch per feature`, () => {
    const features = sampleFeatures();
    const html = renderToStaticMarkup(
      <FeaturesView
        snap={{ features, featuresStatus: "ready", featuresStyle: style, query: "" }}
        store={{ loadFeatures: async () => {}, setFeature: async () => {} }}
        strings={strings}
      />,
    );
    expect(html).toContain(`data-features-style="${style}"`);
    expect(html.match(/role="switch"/g)?.length).toBe(features.length);
  });
}

test("an older daemon without apps.features says to update", () => {
  const html = renderToStaticMarkup(
    <FeaturesView
      snap={{ features: [], featuresStatus: "error", featuresUnsupported: true, featuresStyle: "list", query: "" }}
      store={{ loadFeatures: async () => {}, setFeature: async () => {} }}
      strings={strings}
    />,
  );
  expect(html).toContain(en["store.features.unsupported"]!);
});
