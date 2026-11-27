// Updates > Web UI: the card shows the web UI a NIGHTLY build serves (host lists `web_updates`, the
// app's WebUpdates), follows each change live, words the check in plain language, and its buttons
// send the host's Check Now and Roll Back ops. A bundle that takes no web updates shows no card.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { WebUpdatesState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="web-updates"]');
const button = (element: HTMLElement, action: string) =>
  element.querySelector<HTMLButtonElement>(`[data-web-updates="${action}"]`)!;
const bundled: WebUpdatesState = {
  channel: "every-merge",
  phase: "idle",
  served: null,
  active: null,
  previous: null,
  pending: null,
  last_check: 1_792_000_000,
  refusal: "not_newer",
};
const update = { commit: "765fb01ac29f0123456789abcdef0123456789ab", committed_at: 1_792_000_000 };
const active: WebUpdatesState = { ...bundled, served: update, active: update };

async function show(state: WebUpdatesState | null, failing: Record<string, string> = {}) {
  const page = await renderPage({ path: "/settings/updates", mock: { failing } });
  await act(async () => page.provider.setHost({ ...page.provider.host, web_updates: state }));
  await settle();
  return page;
}

test("no web updates on this bundle: no card", async () => {
  const page = await show(null);
  expect(card(page.container)).toBeNull();
  page.unmount();
});

test("the built-in web UI: Built in, nothing to roll back", async () => {
  const page = await show(bundled);
  const element = card(page.container)!;
  expect(element.textContent).toContain("Built in");
  expect(element.textContent).toContain("Up to date.");
  expect(button(element, "rollback").disabled).toBe(true);
  expect(button(element, "check").disabled).toBe(false);
  page.unmount();
});

test("an update: its short commit; a pending roll back keeps it served until the swap", async () => {
  const page = await show(active);
  expect(card(page.container)!.textContent).toContain("765fb01,");
  expect(card(page.container)!.textContent).not.toContain("765fb01a");
  await act(async () =>
    page.provider.setHost({ ...page.provider.host, web_updates: { ...bundled, served: update, pending: "bundled" } }),
  );
  await settle();
  let element = card(page.container)!;
  expect(element.textContent).toContain("765fb01,");
  expect(element.textContent).toContain("The built-in web UI loads the next time cmux is in the background.");
  await act(async () => page.provider.setHost({ ...page.provider.host, web_updates: bundled }));
  await settle();
  element = card(page.container)!;
  expect(element.textContent).toContain("Built in");
  page.unmount();
});

test("a failed check says why in plain words; a check in flight disables both buttons", async () => {
  const page = await show({ ...active, phase: "failed", refusal: "offline" });
  expect(card(page.container)!.dataset.phase).toBe("failed");
  expect(card(page.container)!.textContent).toContain("cmux could not reach the update server.");
  await act(async () =>
    page.provider.setHost({ ...page.provider.host, web_updates: { ...active, phase: "checking" } }),
  );
  await settle();
  expect(button(card(page.container)!, "check").disabled).toBe(true);
  expect(button(card(page.container)!, "rollback").disabled).toBe(true);
  page.unmount();
});

test("Check Now and Roll Back send the host's ops; a refusal says so", async () => {
  const failing: Record<string, string> = {};
  const page = await show(active, failing);
  for (const action of ["check", "rollback"]) {
    await act(async () => button(card(page.container)!, action).click());
    await settle();
    expect(page.provider.log.some((entry) => entry.op === `cmux.settings.web_updates.${action}`)).toBe(true);
  }
  failing["cmux.settings.web_updates.rollback"] = "cmux.settings.web_updates.failed";
  await act(async () => button(card(page.container)!, "rollback").click());
  await settle();
  expect(card(page.container)!.querySelector('[data-web-updates-failed="rollback"]')?.textContent).toBe(
    "cmux could not roll back the web UI.",
  );
  page.unmount();
});
