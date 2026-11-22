import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import generated from "./generated/strings.json";
import { InstalledView } from "./InstalledView";
import type { AppsSnapshot, AppsStore } from "./store";

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
