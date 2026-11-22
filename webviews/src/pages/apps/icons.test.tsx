// The App Store page's host-drawn icons and listing rules (plans/cmux-next/apps-web-DESIGN.md):
// a symbol icon draws as the host's `glyph/` mask, never as initials; Home and the App Store are
// places in cmux, not listings (extensibility-DESIGN.md).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { listedInStore, parseRoute } from "./model";
import { MockAppsProvider, sampleApps } from "./mockProvider";
import { AppIcon } from "./parts";
import { AppsStore } from "./store";
import { APP_STORE_ID, HOME_ID } from "./types";
import { fromListing } from "./wire";

test("fallback initials preserve emoji and combining graphemes", () => {
  const icon = (name: string) => renderToStaticMarkup(<AppIcon name={name} size={40} />);
  expect(icon("🦊 Fox")).toContain(">🦊F<");
  expect(icon("👩🏽‍💻 Developer")).toContain(">👩🏽‍💻D<");
  expect(icon("🇯🇵日")).toContain(">🇯🇵日<");
  expect(icon("Álvaro Perez")).toContain(">ÁP<");
  expect(icon("王秀英")).toContain(">王秀<");
  expect(icon("أحمد محمد")).toContain(">أم<");
  expect(icon("Aleksandra Wiśniewska-Kowalczyk")).toContain(">AW<");
  expect(icon("Jo")).toContain(">JO<");
  expect(icon("J")).toContain(">J<");
  expect(icon("")).toContain(">?<");
  expect(icon("   ")).toContain(">?<");
});

test("a symbol icon draws as the host's glyph mask, never as initials", () => {
  const listing = fromListing({
    app: "cmux/cloud",
    name: "Cloud Machines",
    summary: "",
    publisher: "cmux",
    tier: "first-party",
    version: "1.0.0",
    icon: { symbol: "cloud" },
    categories: [],
    hide_only: true,
    install: null,
  });
  expect(listing.icon).toEqual({ symbol: "cloud" });
  const html = renderToStaticMarkup(<AppIcon icon={listing.icon} name={listing.name} size={40} />);
  expect(html).toContain("glyph/cloud");
  expect(html).not.toContain(">CM<");
});

test("Home and the App Store are never listed", async () => {
  expect(listedInStore({ id: HOME_ID })).toBe(false);
  expect(listedInStore({ id: APP_STORE_ID })).toBe(false);
  const data = sampleApps();
  const template = Object.values(data.details)[0]!;
  data.details[HOME_ID] = { ...structuredClone(template), id: HOME_ID, name: "Home" };
  const store = new AppsStore(new MockAppsProvider(data));
  await store.start();
  expect(store.getSnapshot().catalog.some((app) => app.id === HOME_ID)).toBe(false);
  store.stop();
});

test("the store has Discover and Installed only: an old features link opens Discover", () => {
  expect(parseRoute("#/features?category=newTab").tab).toBe("discover");
  expect(parseRoute("#/installed").tab).toBe("installed");
});
