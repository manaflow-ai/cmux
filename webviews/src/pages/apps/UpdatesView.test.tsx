import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import { UpdatesView } from "./UpdatesView";
import type { AppsSnapshot, AppsStore } from "./store";

const strings: Strings = {
  language: "en",
  t: (key) =>
    ({
      "store.action.checkUpdates": "Check for updates",
      "store.action.retry": "Retry",
      "store.action.update": "Update",
      "store.badge.updateAvailable": "Update available",
      "store.updates.available": "%@ updates available",
      "store.updates.empty": "All apps are up to date",
      "store.updates.loading": "Checking for updates…",
      "store.updates.stale": "Update information may be out of date.",
      "store.updates.title": "Updates",
      "store.updates.version": "Version %@",
    })[key] ?? key,
  format: (key, ...args) => {
    const value = strings.t(key);
    return args.reduce((text, arg) => text.replace("%@", arg), value);
  },
};

const snapshot = {
  installed: [
    {
      id: "cmux.github-prs",
      name: "GitHub PRs",
      version: "1.1.0",
      enabled: true,
      hidden: false,
      sandboxed: false,
      source: "default",
      update: { version: "1.2.0" },
    },
  ],
  updates: [{ app: "cmux.github-prs", current_version: "1.1.0", version: "1.2.0" }],
  updatesLoading: false,
  updatesStale: false,
  updatesError: undefined,
} as unknown as AppsSnapshot;

test("renders localized update actions instead of raw lookup keys", () => {
  const store = { refreshUpdates() {}, update() {} } as unknown as AppsStore;
  const html = renderToStaticMarkup(<UpdatesView snap={snapshot} store={store} strings={strings} />);

  expect(html).toContain("Check for updates");
  expect(html).toContain("Update");
  expect(html).not.toContain("store.updates.check");
  expect(html).not.toContain("store.updates.retry");
});

test("a failed update check never also says every app is up to date", () => {
  const store = { refreshUpdates() {}, update() {} } as unknown as AppsStore;
  const failed = { ...snapshot, updates: [], updatesStale: true, updatesError: "offline" } as unknown as AppsSnapshot;
  const html = renderToStaticMarkup(<UpdatesView snap={failed} store={store} strings={strings} />);

  expect(html).toContain("Update information may be out of date.");
  expect(html).not.toContain("All apps are up to date");
});
