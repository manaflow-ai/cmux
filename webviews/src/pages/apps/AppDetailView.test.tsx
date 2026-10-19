import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import { AppDetailView } from "./AppDetailView";
import { AppsPage } from "./AppsPage";
import generated from "./generated/strings.json";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore as Store, type AppsSnapshot, type AppsStore } from "./store";
import { AppsOps } from "./types";

const en = (generated as Record<string, Record<string, string>>).en!;
const strings: Strings = {
  language: "en",
  t: (key) => en[key] ?? key,
  format: (key, ...args) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
};
const store = { select() {}, retryDetail() {} } as unknown as AppsStore;

function render(detailStatus: string): string {
  const snap = { selection: "cmux.github-prs", detail: undefined, detailStatus, grants: {} } as unknown as AppsSnapshot;
  return renderToStaticMarkup(<AppDetailView snap={snap} store={store} strings={strings} showsBack />);
}

test("a normal detail load reads as loading, not as a store failure", () => {
  const html = render("loading");
  expect(html).toContain('data-detail-state="loading"');
  expect(html).toContain(en["store.detail.loading"]!);
  expect(html).not.toContain(en["store.error.load"]!);
  expect(html).not.toContain(en["store.updates.loading"]!);
  expect(html).not.toContain('role="alert"');
});

test("a missing app says so instead of reusing the search empty state", () => {
  const html = render("not-found");
  expect(html).toContain(en["store.detail.notFound"]!);
  expect(html).not.toContain(en["store.empty.noMatches"]!);
});

test("a failed catalog does not also claim that no apps match", async () => {
  const provider = new MockAppsProvider();
  provider.failNext(AppsOps.catalogList, new Error("supervisor unavailable"));
  const failing = new Store(provider);
  await failing.start();
  const html = renderToStaticMarkup(<AppsPage store={failing} strings={strings} />);
  failing.stop();
  expect(html).toContain(en["store.error.load"]!);
  expect(html).not.toContain(en["store.empty.noMatches"]!);
});
