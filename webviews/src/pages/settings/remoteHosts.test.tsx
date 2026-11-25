import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(restore);
const { renderPage, click, run } = await import("./testing");
let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});
const entry = () => page!.container.querySelector<HTMLButtonElement>("[data-remote-hosts-connect]");
const remoteRuns = () => page!.provider.actionsRun.filter(({ action }) => action === "remote.newGroup");

test("Devices does not expose or invoke the remote experiment by default", async () => {
  page = await renderPage({ path: "/settings/devices" });
  expect(entry()).toBeNull();
  expect(remoteRuns()).toEqual([]);
});

test("Labs opt-in exposes the existing picker; mount and opt-out never connect", async () => {
  page = await renderPage({ path: "/settings/devices", mock: { values: { "labs.previewFeatures": true } } });
  expect(entry()).not.toBeNull();
  expect(remoteRuns()).toEqual([]);
  await click(entry()!);
  expect(remoteRuns()).toEqual([{ action: "remote.newGroup", args: {} }]);
  await run(() => page!.store.set("labs.previewFeatures", false));
  expect(entry()).toBeNull();
  expect(remoteRuns()).toHaveLength(1);
});

test("a refused picker stays visible with an error and can be retried", async () => {
  page = await renderPage({
    path: "/settings/devices",
    mock: { values: { "labs.previewFeatures": true }, actionRan: false },
  });
  await click(entry()!);
  expect(page.container.querySelector('[data-devices-group="remote-hosts"] [role="alert"]')?.textContent).toBeTruthy();
  expect(entry()!.disabled).toBe(false);
  await click(entry()!);
  expect(remoteRuns()).toHaveLength(2);
});

test("a bridge failure is visible and releases the busy state", async () => {
  page = await renderPage({
    path: "/settings/devices",
    mock: { values: { "labs.previewFeatures": true }, failing: { "cmux.app.action.run": "cmux.page.refused" } },
  });
  await click(entry()!);
  expect(page.container.querySelector('[data-devices-group="remote-hosts"] [role="alert"]')?.textContent).toBeTruthy();
  expect(entry()!.disabled).toBe(false);
});
