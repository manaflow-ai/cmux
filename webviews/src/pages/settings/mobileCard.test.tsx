// Settings > Mobile: its own category with the schema switch mobile.allowIPhoneConnections and the
// host's iPhone card (host lists `iphone`), which follows the host live; Accounts no longer has it.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { IPhoneHostState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="mobile"]');
const state: IPhoneHostState = {
  title: "Connection",
  allowed: true,
  status_title: "Status",
  status: "Online · Phones connected: 1",
  phase: "online",
  space_title: "Space",
  space: "Personal",
  how_title: "How to Connect",
  how: "Install cmux cnx",
  phones_title: "Connected Phones",
  phones_empty: "No phones are connected.",
  phones: [{ id: "s1", title: "iPhone 1a2b", subtitle: "WireGuard · Relayed", transport: "wireguard", path: "relay" }],
};

test("Mobile is its own category with the allow switch; Accounts has no iPhone card", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: state }));
  await settle();
  expect(page.container.querySelector('[data-row-key="mobile.allowIPhoneConnections"]')).not.toBeNull();
  expect(card(page.container)).not.toBeNull();
  page.unmount();
  const accounts = await renderPage({ path: "/settings/accounts" });
  await act(async () => accounts.provider.setHost({ ...accounts.provider.host, iphone: state }));
  await settle();
  expect(card(accounts.container)).toBeNull();
  accounts.unmount();
});

test("the card shows status, space and phones with their transport, and follows the host", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: state }));
  await settle();
  const element = card(page.container)!;
  expect(element.dataset.phase).toBe("online");
  expect(element.textContent).toContain("Online · Phones connected: 1");
  expect(element.textContent).toContain("Personal");
  const phone = element.querySelector<HTMLElement>("[data-mobile-phone]")!;
  expect([phone.dataset.transport, phone.dataset.path]).toEqual(["wireguard", "relay"]);
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: { ...state, phones: [] } }));
  await settle();
  expect(card(page.container)!.textContent).toContain("No phones are connected.");
  await act(async () =>
    page.provider.setHost({ ...page.provider.host, iphone: { ...state, allowed: false, space: null, phase: "off" } }),
  );
  await settle();
  expect(card(page.container)!.querySelector("[data-mobile-phones]")).toBeNull();
  expect(card(page.container)!.textContent).not.toContain("Personal");
  page.unmount();
});

test("the switch writes the setting through cmux.settings.set", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  await settle();
  const toggle = page.container.querySelector<HTMLButtonElement>('[role="switch"]')!;
  await act(async () => toggle.click());
  await settle();
  const writes = page.provider.log.filter((entry) => entry.op === "cmux.settings.set");
  expect(writes.map((entry) => (entry.params as { key: string }).key)).toContain("mobile.allowIPhoneConnections");
  page.unmount();
});
