// Updates > App Update: the card shows the host's update status (host lists `app_update`), follows
// it live, draws the download's bar, and its buttons send cmux.settings.app_update.run. A host
// with no updater shows no card.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { AppUpdateState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="app-update"]');
const downloading: AppUpdateState = {
  title: "App Update",
  phase: "downloading",
  status: "Downloading Update",
  detail: "57.3 MB of 257.1 MB · 22%",
  progress: 0.22,
  actions: [{ id: "cancel_download", title: "Cancel", prominent: false }],
};
const ready: AppUpdateState = {
  ...downloading,
  phase: "ready",
  status: "Update Ready",
  detail: null,
  progress: undefined,
  actions: [{ id: "install", title: "Restart to Update", prominent: true }],
};

async function show(state: AppUpdateState | null) {
  const page = await renderPage({ path: "/settings/updates" });
  await act(async () => page.provider.setHost({ ...page.provider.host, app_update: state }));
  await settle();
  return page;
}

test("no updater: no card", async () => {
  const page = await show(null);
  expect(card(page.container)).toBeNull();
  page.unmount();
});

test("a download shows its bytes, its bar and Cancel", async () => {
  const page = await show(downloading);
  const element = card(page.container)!;
  expect(element.dataset.phase).toBe("downloading");
  expect(element.textContent).toContain("57.3 MB of 257.1 MB");
  const bar = element.querySelector<HTMLProgressElement>("[data-app-update-progress]")!;
  expect(bar.value).toBe(22);
  expect(element.querySelector('[data-app-update="cancel_download"]')).not.toBeNull();
  page.unmount();
});

test("the staged update offers one Restart to Update, which sends install", async () => {
  const page = await show(downloading);
  await act(async () => page.provider.setHost({ ...page.provider.host, app_update: ready }));
  await settle();
  const element = card(page.container)!;
  expect(element.querySelector("[data-app-update-progress]")).toBeNull();
  const restart = element.querySelector<HTMLButtonElement>('[data-app-update="install"]')!;
  expect(restart.textContent).toBe("Restart to Update");
  await act(async () => restart.click());
  await settle();
  expect(page.provider.log).toContainEqual({ op: "cmux.settings.app_update.run", params: { action: "install" } });
  page.unmount();
});
