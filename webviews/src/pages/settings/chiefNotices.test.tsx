// Settings > Chief > Notices (Leo's list): the Chief's notices are the app's notifications, so the
// Chief page has one Notices row that opens Settings > Notifications. It links, never copies: a
// setting has one home on the page (SettingsPageLayoutHomeTests), so no Notifications row is drawn
// on the Chief page.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");
const { parseLocation } = await import("./router");
const { categoryById } = await import("./categories");

test("the Chief page has a Notices row that opens Settings > Notifications", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  const notices = page.container.querySelector<HTMLElement>('[data-card="notices"]');
  expect(notices?.querySelector(".row-title")?.textContent).toBe("Notices");
  await click(notices!.querySelector<HTMLButtonElement>("button")!);
  await settle();
  expect(parseLocation(page.history.location.href).section).toBe("notifications");
  expect(page.container.querySelector('[data-section="notifications"]')).not.toBeNull();
  page.unmount();
});

test("the Notices row draws none of Notifications' settings", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  const shown = [...page.container.querySelectorAll<HTMLElement>(".row[data-row-key]")].map(
    (row) => row.dataset.rowKey,
  );
  const notifications = categoryById("notifications").groups.flatMap((group) => group.rows.map((row) => row.key));
  expect(notifications.length).toBeGreaterThan(0);
  expect(shown.filter((key) => notifications.includes(key!))).toEqual([]);
  page.unmount();
});
