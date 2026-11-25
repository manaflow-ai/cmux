// Settings > Notifications' first card (cmux#55600): macOS denied cmux notifications on NIGHTLY and
// nothing in cmux said so. The card shows the permission the host last read: denied says banners are
// blocked with Open System Settings, not yet asked offers Allow Notifications, and a launch that never
// asks (null) draws nothing.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, ops } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="notification-permission"]');
const button = (container: HTMLElement) => card(container)!.querySelector<HTMLButtonElement>("button")!;

test("denied notifications show Blocked with Open System Settings, which runs allow", async () => {
  const page = await renderPage({
    path: "/settings/notifications",
    setup: (provider) =>
      provider.setHost({ ...provider.host, notification_permission: { authorization: "denied", sound: true } }),
  });
  await settle();
  expect(card(page.container)?.querySelector(".row-title")?.textContent).toBe("macOS Notifications");
  expect(card(page.container)?.querySelector("output")?.textContent).toBe("Blocked");
  expect(card(page.container)?.querySelector("output")?.getAttribute("data-tone")).toBe("warning");
  expect(button(page.container).textContent).toBe("Open System Settings");
  await click(button(page.container));
  await settle();
  expect(ops(page.provider, "cmux.settings.notification_permission.allow")).toEqual([{}]);
  page.unmount();
});

test("not yet asked offers Allow Notifications, and the answer shows", async () => {
  const page = await renderPage({
    path: "/settings/notifications",
    setup: (provider) =>
      provider.setHost({ ...provider.host, notification_permission: { authorization: "not_determined", sound: null } }),
  });
  await settle();
  expect(button(page.container).textContent).toBe("Allow Notifications");
  await click(button(page.container));
  await settle();
  expect(card(page.container)?.getAttribute("data-authorization")).toBe("authorized");
  expect(card(page.container)?.querySelector("output")?.textContent).toBe("Allowed");
  page.unmount();
});

test("a launch that never asks draws no card", async () => {
  const page = await renderPage({
    path: "/settings/notifications",
    setup: (provider) => provider.setHost({ ...provider.host, notification_permission: null }),
  });
  await settle();
  expect(page.container.querySelector('[data-section="notifications"]')).not.toBeNull();
  expect(card(page.container)).toBeNull();
  page.unmount();
});
