// Settings > Privacy and Security > Shared Links: every live chat share this Mac's daemon holds, newest
// first, each with its chat, kind, dates and the guests in it now; Revoke ends one at once, Revoke All
// asks first and ends every one; an ended share is never listed; the card deep link lands on it.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockSettingsProvider } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");
const { sharedLinkRows } = await import("./sharedLinks");
const { mockShares } = await import("./mockProvider");

const scrolled: string[] = [];
const view = globalThis.window.HTMLElement.prototype;
const original = view.scrollIntoView;
view.scrollIntoView = function (this: HTMLElement) {
  if (this.dataset.card) scrolled.push(this.dataset.card);
};
afterAll(() => {
  view.scrollIntoView = original;
});

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
  scrolled.length = 0;
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="sharedLinks"]')!;
const rowIds = () =>
  [...card().querySelectorAll<HTMLElement>("[data-shared-link]")].map((row) => row.dataset.sharedLink);

async function open(setup?: (provider: MockSettingsProvider) => void, path = "/settings/privacy") {
  page = await renderPage({ path, setup });
  await settle();
  return page;
}

test("rows: live shares only, newest first, with the chat's title, kind and guests in it now", () => {
  const now = Date.UTC(2026, 10, 7, 12);
  const rows = sharedLinkRows(mockShares(now), now);
  expect(rows.map((row) => row.id)).toEqual(["sh_link_0001", "sh_invite_0002"]);
  expect(rows[0]).toMatchObject({ chat: "Fix the flaky login test", kind: "link", guests: ["Sam"] });
  expect(rows[1]).toMatchObject({ chat: "Plan the onboarding redesign", kind: "people", invited: 2, guests: [] });
  // A share past its end is not listed even before the daemon marks it expired.
  expect(sharedLinkRows(mockShares(now), now + 23 * 3_600_000).map((row) => row.id)).toEqual(["sh_invite_0002"]);
  expect(sharedLinkRows({ available: false }, now)).toEqual([]);
});

test("the card lists each shared chat with its kind and who is in it", async () => {
  await open();
  expect(rowIds()).toEqual(["sh_link_0001", "sh_invite_0002"]);
  const link = card().querySelector<HTMLElement>('[data-shared-link="sh_link_0001"]')!;
  expect(link.textContent).toContain("Fix the flaky login test");
  expect(link.querySelector("[data-shared-link-detail]")!.textContent).toContain("Guest link");
  expect(link.querySelector("[data-shared-link-guests]")!.textContent).toContain("Sam");
  const invite = card().querySelector<HTMLElement>('[data-shared-link="sh_invite_0002"]')!;
  expect(invite.querySelector("[data-shared-link-detail]")!.textContent).toContain("People: 2");
});

test("Revoke ends that share at once and the row leaves", async () => {
  await open();
  await click(card().querySelector<HTMLButtonElement>('[data-shared-link="sh_link_0001"] [data-shared-link-action]')!);
  await settle();
  expect(page!.provider.shareRevokes).toEqual(["sh_link_0001"]);
  expect(rowIds()).toEqual(["sh_invite_0002"]);
  // One row left: no Revoke All.
  expect(card().querySelector('[data-shared-links-action="revokeAll"]')).toBeNull();
});

test("Revoke All asks first; Cancel keeps every share, confirming ends them all", async () => {
  await open();
  await click(card().querySelector<HTMLButtonElement>('[data-shared-links-action="revokeAll"]')!);
  expect(card().querySelector("[data-shared-links-confirm]")).not.toBeNull();
  expect(page!.provider.shareRevokes).toEqual([]);
  await click(card().querySelector<HTMLButtonElement>('[data-shared-links-action="cancel"]')!);
  expect(card().querySelector("[data-shared-links-confirm]")).toBeNull();
  await click(card().querySelector<HTMLButtonElement>('[data-shared-links-action="revokeAll"]')!);
  await click(card().querySelector<HTMLButtonElement>('[data-shared-links-action="confirmRevokeAll"]')!);
  await settle();
  expect(page!.provider.shareRevokes).toEqual(["sh_link_0001", "sh_invite_0002"]);
  expect(rowIds()).toEqual([]);
  expect(card().querySelector("[data-shared-links-empty]")).not.toBeNull();
});

test("no shares: one line; daemon not connected: one line", async () => {
  await open((provider) => {
    provider.shares = { available: true, shares: [], titles: {} };
  });
  expect(card().querySelector("[data-shared-links-empty]")!.textContent).toBe("You haven’t shared any chats.");
  page!.unmount();
  await open((provider) => {
    provider.shares = { available: false };
  });
  expect(card().querySelector("[data-shared-links-unavailable]")).not.toBeNull();
  expect(rowIds()).toEqual([]);
});

test("the card deep link opens Settings at Shared Links", async () => {
  await open(undefined, "/settings/privacy?focus=card.sharedLinks");
  expect(page!.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("privacy");
  expect(scrolled).toEqual(["sharedLinks"]);
});

test("Privacy opened plainly stays at its top", async () => {
  await open();
  expect(scrolled).toEqual([]);
});
