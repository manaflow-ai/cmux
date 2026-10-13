// Accounts > iPhone: the card draws the host's localized state (host lists `iphone`, the app's
// CnxHostSupervisor), follows it live, and its switch sends cmux.settings.iphone.set.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { IPhoneHostState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="iphone"]');
const state: IPhoneHostState = {
  title: "iPhone",
  allowed: true,
  enabled: true,
  allow_title: "Allow iPhone Connections",
  allow_help: "help",
  status_title: "Status",
  status: "Online · Phones connected: 1",
  phase: "online",
  how_title: "How to Connect",
  how: "Install cmux cnx",
  phones_title: "Connected Phones",
  phones_empty: "No phones are connected.",
  phones: [{ id: "s1", title: "iPhone 1a2b", subtitle: "WireGuard · Relay" }],
};

test("no iphone state, no card", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  await settle();
  expect(card(page.container)).toBeNull();
  page.unmount();
});

test("the card shows status and phones, and follows a change live", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: state }));
  await settle();
  const element = card(page.container)!;
  expect(element.dataset.phase).toBe("online");
  expect(element.textContent).toContain("Online · Phones connected: 1");
  expect(element.querySelectorAll("[data-iphone-phone]").length).toBe(1);
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: { ...state, phones: [] } }));
  await settle();
  expect(card(page.container)!.textContent).toContain("No phones are connected.");
  page.unmount();
});

test("the switch sends cmux.settings.iphone.set; a disabled switch sends nothing", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: state }));
  await settle();
  await act(async () => card(page.container)!.querySelector<HTMLButtonElement>('[role="switch"]')!.click());
  await settle();
  const sent = page.provider.log.filter((entry) => entry.op === "cmux.settings.iphone.set");
  expect(sent.map((entry) => (entry.params as { allowed: boolean }).allowed)).toEqual([false]);
  expect(card(page.container)!.querySelector('[role="switch"]')!.getAttribute("aria-checked")).toBe("false");
  expect(card(page.container)!.querySelector("[data-iphone-phones]")).toBeNull();
  await act(async () =>
    page.provider.setHost({ ...page.provider.host, iphone: { ...state, allowed: false, enabled: false } }),
  );
  await settle();
  expect(card(page.container)!.querySelector<HTMLButtonElement>('[role="switch"]')!.disabled).toBe(true);
  page.unmount();
});
