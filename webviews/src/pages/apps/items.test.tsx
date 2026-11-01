// The App Store's item primitives (items.tsx): one card in three styles, one row, one action, the
// state badge, the category bar and the detail sections draw every listing the same way.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import generated from "./generated/strings.json";
import {
  AddsList,
  CategoryBar,
  DetailSection,
  ItemAction,
  ItemCard,
  ItemRow,
  ItemSettings,
  ScreenshotStrip,
  StateBadge,
} from "./items";
import { itemState, parseCardStyle, parseRoute, type CardStyle } from "./model";
import { AppsStore } from "./store";
import type { AppDetail, CatalogApp } from "./types";
import { fromDetail, type WireDetail } from "./wire";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
};
const store = {} as AppsStore;

const app = (overrides: Partial<CatalogApp> = {}): CatalogApp => ({
  id: "acme.caffeinate",
  name: "Caffeinate",
  description: "Keeps the Mac awake while an agent works.",
  publisher: "Acme",
  publisher_verified: true,
  tier: "verified",
  categories: ["productivity"],
  latest_version: "2.0.1",
  install_count: 0,
  installed: false,
  ...overrides,
});

const card = (style: CardStyle, overrides: Partial<CatalogApp> = {}) =>
  renderToStaticMarkup(<ItemCard app={app(overrides)} store={store} strings={strings} style={style} />);

test("the card style comes from the route and defaults to standard", () => {
  expect(parseCardStyle(undefined)).toBe("standard");
  expect(parseCardStyle("bogus")).toBe("standard");
  expect(parseCardStyle("compact")).toBe("compact");
  expect(parseRoute("#/discover?layout=grid").card).toBe("standard");
  expect(parseRoute("#/discover?layout=grid&card=artwork").card).toBe("artwork");
});

test("a route change switches the card style on an open page", () => {
  const page = new AppsStore(null, "#/discover");
  expect(page.getSnapshot().card).toBe("standard");
  page.applyRoute("#/discover?card=compact");
  expect(page.getSnapshot().card).toBe("compact");
});

test("an item is available, installed, or installed and off", () => {
  expect(itemState({ installed: false })).toBe("available");
  expect(itemState({ installed: true })).toBe("installed");
  expect(itemState({ installed: true, enabled: true })).toBe("installed");
  expect(itemState({ installed: true, enabled: false })).toBe("off");
});

test("the state badge says Installed or Disabled, and nothing before install", () => {
  const badge = (overrides: Partial<CatalogApp>) =>
    renderToStaticMarkup(<StateBadge app={app(overrides)} strings={strings} />);
  expect(badge({})).toBe("");
  expect(badge({ installed: true })).toContain(en["store.badge.installed"]!);
  expect(badge({ installed: true, enabled: false })).toContain(en["store.badge.disabled"]!);
});

test("the action is Install, Remove, or Hide/Show for an app that ships with cmux", () => {
  const action = (overrides: Partial<CatalogApp>) =>
    renderToStaticMarkup(<ItemAction app={app(overrides)} store={store} strings={strings} />);
  expect(action({})).toContain('class="apps-button primary"');
  expect(action({})).toContain(`>${en["store.action.install"]}<`);
  expect(action({ installed: true })).toContain(`>${en["store.action.remove"]}<`);
  expect(action({ installed: true, tier: "first-party" })).toContain(`>${en["store.action.hide"]}<`);
  expect(action({ installed: true, hide_only: true, hidden: true })).toContain(`>${en["store.action.show"]}<`);
  expect(action({ installed: true, hide_only: true })).not.toContain(en["store.action.remove"]!);
});

test("the standard card keeps its classes, badges, Preview and the action", () => {
  const html = card("standard", { installed: true, enabled: false });
  expect(html).toContain('class="apps-card"');
  expect(html).toContain('data-card-style="standard"');
  expect(html).toContain('data-item-state="off"');
  expect(html).toContain("apps-card-footer");
  expect(html).toContain(en["store.tier.verified"]!);
  expect(html).toContain(en["store.badge.disabled"]!);
  expect(html).toContain(en["store.detail.preview"]!);
  expect(html).toContain(en["store.action.remove"]!);
  expect(html).not.toContain("one-line");
});

test("the compact card is one line of description and the action, with no footer", () => {
  const html = card("compact");
  expect(html).toContain('class="apps-card compact"');
  expect(html).toContain("apps-description one-line");
  expect(html).toContain(en["store.action.install"]!);
  expect(html).not.toContain("apps-card-footer");
  expect(html).not.toContain(en["store.detail.preview"]!);
});

test("the artwork card puts the icon on its panel inside the open button", () => {
  const html = card("artwork");
  expect(html).toContain('class="apps-card artwork"');
  expect(html).toMatch(/<button[^>]*apps-card-open[^>]*><span class="apps-card-art">/);
  expect(html).toContain("apps-card-footer");
});

test("every style names the app, its description and its state for tests and assistive tech", () => {
  for (const style of ["standard", "compact", "artwork"] as const) {
    const html = card(style, { installed: true });
    expect(html).toContain('aria-label="Caffeinate"');
    expect(html).toContain('aria-describedby="apps-description-acme-caffeinate"');
    expect(html).toContain('data-item-state="installed"');
  }
});

test("the row keeps its look: the tier and the action, no state badge", () => {
  const html = renderToStaticMarkup(
    <ItemRow app={app({ installed: true })} selected store={store} strings={strings} />,
  );
  expect(html).toContain('class="apps-row selected"');
  expect(html).toContain('data-item-state="installed"');
  expect(html).not.toContain(en["store.badge.installed"]!);
  expect(html).toContain(en["store.action.remove"]!);
});

test("the category bar leads with All and presses the selected category", () => {
  const bar = (selected?: string) =>
    renderToStaticMarkup(
      <CategoryBar categories={["git", "agents"]} selected={selected} onSelect={() => {}} strings={strings} />,
    );
  expect(bar()).toMatch(/aria-pressed="true"[^>]*>All</);
  const git = bar("git");
  expect(git).toMatch(/class="apps-chip selected" aria-pressed="true"[^>]*>Git</);
  expect(git).toMatch(/aria-pressed="false"[^>]*>All</);
});

test("the screenshots strip shows for any listed screenshot and draws only data images", () => {
  expect(renderToStaticMarkup(<ScreenshotStrip screenshots={[]} strings={strings} />)).toBe("");
  const remote = renderToStaticMarkup(
    <ScreenshotStrip screenshots={["https://example.com/a.png"]} strings={strings} />,
  );
  expect(remote).toContain(`<h2>${en["store.detail.screenshots"]}</h2>`);
  expect(remote).not.toContain("<img");
  const html = renderToStaticMarkup(
    <ScreenshotStrip screenshots={["data:image/png;base64,AAAA", "https://example.com/a.png"]} strings={strings} />,
  );
  expect(html.match(/<img/g)?.length).toBe(1);
});

test("a detail section is a titled section", () => {
  const html = renderToStaticMarkup(
    <DetailSection title="Versions">
      <p>1.0.0</p>
    </DetailSection>,
  );
  expect(html).toBe('<section class="apps-section"><h2>Versions</h2><p>1.0.0</p></section>');
});

test("What it adds lists each contribution with its kind, and is absent when there are none", () => {
  expect(renderToStaticMarkup(<AddsList contributes={[]} strings={strings} />)).toBe("");
  expect(renderToStaticMarkup(<AddsList strings={strings} />)).toBe("");
  const html = renderToStaticMarkup(
    <AddsList
      contributes={[
        { kind: "section", title: "Pull Requests" },
        { kind: "panel", title: "Inbox" },
      ]}
      strings={strings}
    />,
  );
  expect(html).toContain(`<h2>${en["store.detail.adds"]}</h2>`);
  expect(html).toContain("Pull Requests");
  expect(html).toContain(en["store.contribution.section"]!);
  expect(html).toContain(">panel<");
  const twice = renderToStaticMarkup(
    <AddsList
      contributes={[
        { kind: "command", title: "Stay Awake" },
        { kind: "command", title: "Stay Awake" },
      ]}
      strings={strings}
    />,
  );
  expect(twice.match(/Stay Awake/g)?.length).toBe(2);
  const inherited = renderToStaticMarkup(
    <AddsList
      contributes={[
        { kind: "__proto__", title: "Odd" },
        { kind: "constructor", title: "Odder" },
      ]}
      strings={strings}
    />,
  );
  expect(inherited).toContain(">__proto__<");
  expect(inherited).toContain(">constructor<");
});

test("settings show only once installed, with Enabled as the app's switch", () => {
  const settings = (overrides: Partial<CatalogApp>) =>
    renderToStaticMarkup(<ItemSettings app={app(overrides)} store={store} strings={strings} />);
  expect(settings({})).toBe("");
  const on = settings({ installed: true });
  expect(on).toContain(`<h2>${en["store.detail.settings"]}</h2>`);
  expect(on).toContain('aria-checked="true"');
  expect(settings({ installed: true, enabled: false })).toContain('aria-checked="false"');
});

test("the detail keeps the owner's contributions and drops untitled ones", () => {
  const wire = {
    app: "acme.caffeinate",
    name: "Caffeinate",
    summary: "",
    publisher: "Acme",
    tier: "verified",
    version: "2.0.1",
    icon: null,
    categories: [],
    hide_only: false,
    install: null,
    scopes: [],
    contributes: [
      { kind: "command", title: "Stay Awake" },
      { kind: "command", title: " " },
    ],
  } satisfies WireDetail;
  const detail: AppDetail = fromDetail(wire);
  expect(detail.contributes).toEqual([{ kind: "command", title: "Stay Awake" }]);
  expect(fromDetail({ ...wire, contributes: undefined }).contributes).toBeUndefined();
  // A malformed payload never throws: a non-array is no list, and bad entries are dropped.
  const malformed = (contributes: unknown) => fromDetail({ ...wire, contributes } as unknown as WireDetail).contributes;
  expect(malformed("Stay Awake")).toBeUndefined();
  expect(malformed({ kind: "command", title: "Stay Awake" })).toBeUndefined();
  expect(
    malformed([
      null,
      7,
      { kind: { x: 1 }, title: "Bad" },
      { kind: null, title: "Bad" },
      { kind: "panel", title: "Inbox" },
    ]),
  ).toEqual([{ kind: "panel", title: "Inbox" }]);
});
