// Settings > Browser > Autofill and passwords (Lawrence 2026-10-28): Password manager and Contact
// info, each with Manage, which opens Chromium's own page (chrome://password-manager,
// chrome://settings/addresses) in the chosen browser profile through the one catalog action the
// palette also runs. The card is found by search too.
import { act } from "react";
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, renderPage, settle } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const lastRun = (page: Rendered) =>
  page.provider.log.filter((entry) => entry.op === "cmux.app.action.run").at(-1)?.params;

test("Manage opens Chromium's password manager and contact info in the default profile", async () => {
  page = await renderPage({ path: "/settings/browser" });
  const card = page.container.querySelector<HTMLElement>('[data-card="autofill"]');
  expect(card).not.toBeNull();
  const passwords = card!.querySelector<HTMLElement>('[data-autofill="passwords"]')!;
  const addresses = card!.querySelector<HTMLElement>('[data-autofill="addresses"]')!;
  expect(passwords.textContent).toContain("Password Manager");
  expect(addresses.textContent).toContain("Contact Info");

  await act(async () => passwords.querySelector<HTMLButtonElement>("[data-manage]")!.click());
  await settle();
  expect(lastRun(page)).toEqual({
    action: "browserProfile.managePasswords",
    args: {},
    target: "browser-profile:p-default",
  });

  await act(async () => addresses.querySelector<HTMLButtonElement>("[data-manage]")!.click());
  await settle();
  expect(lastRun(page)).toEqual({
    action: "browserProfile.manageAddresses",
    args: {},
    target: "browser-profile:p-default",
  });
});

test("with more than one browser profile, Manage opens the chosen profile's page", async () => {
  page = await renderPage({ path: "/settings/browser" });
  const card = page.container.querySelector<HTMLElement>('[data-card="autofill"]')!;
  const picker = card.querySelector<HTMLSelectElement>("select[data-autofill-profile]")!;
  expect(picker).not.toBeNull();
  await act(async () => {
    picker.value = "p-work";
    picker.dispatchEvent(new Event("change", { bubbles: true }));
  });
  const passwords = card.querySelector<HTMLElement>('[data-autofill="passwords"]')!;
  await act(async () => passwords.querySelector<HTMLButtonElement>("[data-manage]")!.click());
  await settle();
  expect(lastRun(page)).toEqual({
    action: "browserProfile.managePasswords",
    args: {},
    target: "browser-profile:p-work",
  });
});

test("search finds the Autofill and passwords card", async () => {
  page = await renderPage({ path: "/settings/general" });
  const search = page.container.querySelector<HTMLInputElement>("[data-settings-search]")!;
  await changeValue(search, "contact info");
  const results = page.container.querySelector<HTMLElement>("[data-search-results]")!;
  expect(results.querySelector('[data-card="autofill"]')).not.toBeNull();
  expect(results.querySelector('[data-section="browser"]')?.hasAttribute("data-open")).toBe(true);
  await changeValue(search, "zzzz-nothing");
  expect(results.querySelector('[data-card="autofill"]')).toBeNull();
});
