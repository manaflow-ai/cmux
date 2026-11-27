// Use as New Tab (UseAsNewTab.tsx): an installed app with a New Tab view (`cmux.newtab/1`) offers
// it on its card, the person's click sets `tabs.newTabApp` to the app id through the host, and the
// page follows the setting when another writer changes it.
import { expect, test } from "bun:test";
import { isValidElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { pageError } from "../shared/pageClient";
import type { Strings } from "../shared/i18n";
import generated from "./generated/strings.json";
import { ItemCard } from "./items";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore } from "./store";
import type { CatalogApp } from "./types";
import { NewTabChoice, NewTabChoiceProvider, NewTabControls, NewTabOps } from "./UseAsNewTab";
import { fromInstalled, fromListing } from "./wire";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
};
const store = {} as AppsStore;
const USE = en["store.action.useAsNewTab"]!;
const STOP = en["store.action.stopNewTab"]!;
const ON = en["store.badge.onNewTab"]!;

const app = (overrides: Partial<CatalogApp> = {}): CatalogApp => ({
  id: "acme/launcher",
  name: "Launcher",
  description: "Draws above the composer.",
  publisher: "acme",
  publisher_verified: true,
  tier: "verified",
  categories: ["productivity"],
  latest_version: "1.0.0",
  install_count: 0,
  installed: true,
  new_tab: true,
  ...overrides,
});

const card = (listing: CatalogApp, newTabApp?: string) =>
  renderToStaticMarkup(
    <NewTabChoiceProvider value={new NewTabChoice(null, { app: newTabApp })}>
      <ItemCard app={listing} store={store} strings={strings} style="standard" />
    </NewTabChoiceProvider>,
  );

test("only an installed app with a New Tab view offers Use as New Tab on its card", () => {
  expect(card(app())).toContain(USE);
  expect(card(app({ new_tab: false }))).not.toContain(USE);
  expect(card(app({ installed: false }))).not.toContain(USE);
  // Without the page's choice (no host), nothing shows.
  expect(renderToStaticMarkup(<ItemCard app={app()} store={store} strings={strings} style="standard" />)).not.toContain(
    USE,
  );
});

test("the app New Tab shows says On New Tab and offers Stop Using as New Tab", () => {
  const current = card(app(), "acme/launcher");
  expect(current).toContain(ON);
  expect(current).toContain(STOP);
  expect(current).not.toContain(USE);
  const other = card(app(), "acme/other");
  expect(other).not.toContain(ON);
  expect(other).toContain(USE);
});

test("a click on Use as New Tab sets the app id; on the current app it resets", () => {
  const writes: (string | undefined)[] = [];
  const click = (current: boolean) => {
    const element = NewTabControls({ app: "acme/launcher", current, onSet: (id) => writes.push(id), strings });
    const children = isValidElement<{ children: unknown[] }>(element) ? element.props.children : [];
    const button = children.find((child) => isValidElement(child) && child.type === "button");
    if (!isValidElement<{ onClick: (event: { stopPropagation(): void }) => void }>(button))
      throw new Error("no button");
    button.props.onClick({ stopPropagation() {} });
  };
  click(false);
  click(true);
  expect(writes).toEqual(["acme/launcher", undefined]);
});

test("the choice reads tabs.newTabApp, writes the app id through the host and follows other writers", async () => {
  const host = new MockAppsProvider();
  host.newTabApp = "cmux.github-prs";
  const choice = new NewTabChoice(host);
  await choice.start();
  expect(choice.getSnapshot().app).toBe("cmux.github-prs");

  await choice.set("acme/launcher");
  expect(host.calls.filter((call) => call.op === NewTabOps.set).map((call) => call.params)).toEqual([
    { app: "acme/launcher" },
  ]);
  expect(host.newTabApp).toBe("acme/launcher");
  expect(choice.getSnapshot().app).toBe("acme/launcher");

  await choice.set(undefined);
  expect(host.calls.at(-1)?.params).toEqual({ app: null });
  expect(choice.getSnapshot().app).toBeUndefined();

  // Settings or `cmux settings set tabs.newTabApp ...`: the open page follows.
  await host.call(NewTabOps.set, { app: "cmux.github-prs" });
  expect(choice.getSnapshot().app).toBe("cmux.github-prs");
  choice.stop();
});

test("a refused write shows its sentence on the row it was made on", async () => {
  const host = new MockAppsProvider();
  host.failNext(NewTabOps.set, pageError("cmux.settings.managed", "managed"));
  const choice = new NewTabChoice(host);
  await choice.set("acme/launcher");
  expect(choice.getSnapshot().error?.app).toBe("acme/launcher");
  expect(choice.getSnapshot().app).toBeUndefined();
});

test("a host without the New Tab ops shows no current New Tab", async () => {
  const host = new MockAppsProvider();
  host.failNext(NewTabOps.get, pageError("cmux.protocol.unknown_op", NewTabOps.get));
  const choice = new NewTabChoice(host);
  await choice.start();
  expect(choice.getSnapshot().app).toBeUndefined();
  choice.stop();
});

test("listings and Installed rows carry new_tab from the owner", () => {
  const listing = fromListing({
    app: "acme/launcher",
    name: "Launcher",
    summary: "s",
    publisher: "acme",
    tier: "verified",
    version: "1.0.0",
    icon: null,
    categories: [],
    hide_only: false,
    new_tab: true,
    install: null,
  });
  expect(listing.new_tab).toBe(true);
  const row = fromInstalled({
    app: "acme/plain",
    name: "Plain",
    tier: "verified",
    hide_only: false,
    state: {
      installed: true,
      enabled: true,
      hidden: false,
      sandboxed: false,
      source: "user",
      version: "1.0.0",
      update: null,
    },
    grants: [],
  });
  expect(row.new_tab).toBe(false);
});
