// The App Store's "Customize cmux…" card (Leo, 2026-11-22, ask-931361017e): at the top of Discover,
// it names the verified looks and opens Settings > Customize, where each customization is one switch.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { VerifiedLook } from "../settings/customizeChecklist";
import type { Strings } from "../shared/i18n";
import { AppsPage } from "./AppsPage";
import { CustomizeFeature, NAMED_LOOKS } from "./CustomizeFeature";
import generated from "./generated/strings.json";
import { MockAppsProvider, storeApps } from "./mockProvider";
import { AppsStore } from "./store";
import { CUSTOMIZE_ACTION } from "./types";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
};

const look = (index: number): VerifiedLook => ({
  id: `a/look-${index}`,
  name: `Look ${index}`,
  tagline: `Tagline ${index}`,
  reference: `github.com/manaflow-ai/cmux/examples/looks/look-${index}@feat-cmux-next`,
  folder: `looks/look-${index}`,
});

test("Discover opens with the Customize cmux… card; another tab does not", async () => {
  const home = new AppsStore(new MockAppsProvider(storeApps()), "#/discover");
  await home.start();
  const html = renderToStaticMarkup(<AppsPage store={home} strings={strings} />);
  home.stop();
  expect(html).toContain('class="apps-customize-feature"');
  expect(html).toContain(en["store.customize.title"]!);
  expect(html.indexOf("apps-customize-feature")).toBeLessThan(html.indexOf('class="apps-hero"'));

  const installed = new AppsStore(new MockAppsProvider(storeApps()), "#/installed");
  await installed.start();
  const other = renderToStaticMarkup(<AppsPage store={installed} strings={strings} />);
  installed.stop();
  expect(other).not.toContain("apps-customize-feature");
});

test("the card names the first looks and counts the rest", () => {
  const looks = Array.from({ length: NAMED_LOOKS + 3 }, (_, index) => look(index));
  const html = renderToStaticMarkup(
    <CustomizeFeature store={{ openCustomize: async () => {} }} strings={strings} looks={looks} />,
  );
  for (const each of looks.slice(0, NAMED_LOOKS)) expect(html).toContain(`>${each.name}</button>`);
  expect(html).not.toContain(`>${looks[NAMED_LOOKS]!.name}<`);
  expect(html).toContain(strings.format("store.customize.more", "3"));
  const none = renderToStaticMarkup(
    <CustomizeFeature store={{ openCustomize: async () => {} }} strings={strings} looks={[]} />,
  );
  expect(none).not.toContain("apps-customize-looks");
});

test("closed, Show All opens the card in place; open, it lists every look and switch group and links to Settings", () => {
  const looks = Array.from({ length: NAMED_LOOKS + 3 }, (_, index) => look(index));
  const closed = renderToStaticMarkup(
    <CustomizeFeature store={{ openCustomize: async () => {} }} strings={strings} looks={looks} />,
  );
  expect(closed).toContain(`aria-expanded="false"`);
  expect(closed).toContain(`>${en["store.customize.show"]}</button>`);
  expect(closed).not.toContain("apps-customize-panel");
  const open = renderToStaticMarkup(
    <CustomizeFeature store={{ openCustomize: async () => {} }} strings={strings} looks={looks} open />,
  );
  expect(open).toContain(`aria-expanded="true"`);
  expect(open).toContain(`>${en["store.customize.hide"]}</button>`);
  for (const each of looks) expect(open).toContain(`>${each.name}</button>`);
  expect(open).not.toContain(strings.format("store.customize.more", "3"));
  for (const key of ["experiments", "labs", "library", "all"])
    expect(open).toContain(`>${en[`store.customize.${key}`]}</button>`);
  expect(open).toContain(
    `class="apps-customize-link">${en["store.customize.settingsLink"]!.replace(">", "&gt;")}</button>`,
  );
});

test("Open runs openSettings on Settings > Customize's card through the app's action", async () => {
  expect(CUSTOMIZE_ACTION).toEqual({
    op: "cmux.app.action.run",
    action: "openSettings",
    args: { setting: "card.customizeChecklist" },
  });
  const provider = new MockAppsProvider(storeApps());
  const store = new AppsStore(provider, "#/discover");
  await store.start();
  await store.openCustomize().catch(() => undefined);
  store.stop();
  const call = provider.calls.find((each) => each.op === CUSTOMIZE_ACTION.op);
  expect(call?.params).toEqual({ action: "openSettings", args: { setting: "card.customizeChecklist" } });
});
