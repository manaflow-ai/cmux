import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import generated from "./generated/strings.json";
import { InstalledView } from "./InstalledView";
import type { AppsSnapshot, AppsStore } from "./store";
import type { InstalledApp } from "./types";
import { NewTabChoice, NewTabChoiceProvider } from "./UseAsNewTab";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
};
const store = {} as unknown as AppsStore;

function render(loading: boolean): string {
  const snap = { installed: [], loading } as unknown as AppsSnapshot;
  return renderToStaticMarkup(<InstalledView snap={snap} store={store} strings={strings} />);
}

test("an Installed tab still loading says so instead of rendering a blank pane", () => {
  const html = render(true);
  expect(html).toContain('data-installed-state="loading"');
  expect(html).toContain('aria-busy="true"');
  expect(html).toContain(en["store.detail.loading"]!);
  expect(html).not.toContain(en["store.empty.noneInstalled"]!);
});

test("an empty Installed tab names the next step in the same state box", () => {
  const html = render(false);
  expect(html).toContain('data-installed-state="empty"');
  expect(html).toContain('class="apps-empty apps-state"');
  expect(html).toContain(en["store.empty.noneInstalled"]!);
  expect(html).toContain(en["store.empty.noneInstalledHint"]!);
});

// Use as New Tab (`tabs.newTabApp`): only an app with a New Tab view (`cmux.newtab/1`) offers it,
// and the app New Tab shows now says On New Tab and offers Stop Using as New Tab.
function installedRow(id: string, newTab: boolean): InstalledApp {
  return {
    id,
    name: id,
    version: "1.0.0",
    enabled: true,
    hidden: false,
    sandboxed: false,
    source: "user",
    new_tab: newTab,
  };
}

function renderInstalled(newTabApp?: string): string {
  const snap = {
    installed: [
      installedRow("acme/launcher", true),
      installedRow("acme/start", true),
      installedRow("acme/plain", false),
    ],
    updates: [],
    updatesLoading: false,
    updatesStale: false,
    grants: {},
    logs: {},
    loading: false,
  } as unknown as AppsSnapshot;
  // The page's tabs.newTabApp as the host answered it (no client: nothing is read or written here).
  const choice = new NewTabChoice(null, { app: newTabApp });
  return renderToStaticMarkup(
    <NewTabChoiceProvider value={choice}>
      <InstalledView snap={snap} store={store} strings={strings} />
    </NewTabChoiceProvider>,
  );
}

/** The markup of one installed row, by its app id. */
function row(html: string, id: string): string {
  const rows = html.split('<section class="apps-installed-row">').slice(1);
  return rows.find((part) => part.includes(`>${id}<`)) ?? "";
}

test("Installed offers Use as New Tab only on apps with a New Tab view", () => {
  const html = renderInstalled();
  expect(row(html, "acme/launcher")).toContain(en["store.action.useAsNewTab"]!);
  expect(row(html, "acme/start")).toContain(en["store.action.useAsNewTab"]!);
  expect(row(html, "acme/plain")).not.toContain(en["store.action.useAsNewTab"]!);
  expect(html).not.toContain(en["store.badge.onNewTab"]!);
});

test("the app New Tab shows says so on its Installed row and offers Stop Using as New Tab", () => {
  const html = renderInstalled("acme/launcher");
  const current = row(html, "acme/launcher");
  expect(current).toContain(en["store.badge.onNewTab"]!);
  expect(current).toContain(en["store.action.stopNewTab"]!);
  expect(current).not.toContain(en["store.action.useAsNewTab"]!);
  expect(row(html, "acme/start")).toContain(en["store.action.useAsNewTab"]!);
  expect(row(html, "acme/start")).not.toContain(en["store.badge.onNewTab"]!);
  expect(row(html, "acme/plain")).not.toContain(en["store.badge.onNewTab"]!);
});
