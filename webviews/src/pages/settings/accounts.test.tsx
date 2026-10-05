// R82 commit 3: Accounts is drawn by the page from the host's state (no "open in window" link).
// Each gesture is one `cmux.settings.accounts.run`; a pasted key is sent once and then cleared,
// and a failed Keychain save shows the host's message in the form.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue } = await import("./testing");

test("Accounts lists the providers by group and refreshes detection when it opens", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  const text = page.container.textContent ?? "";
  expect(text).toContain("ChatGPT and Codex");
  expect(text).toContain("pro · From ~/.codex/auth.json");
  expect(text).not.toContain("Open in Window");
  expect(page.provider.accountRuns.map((run) => run.action)).toContain("refresh");
  page.unmount();
});

test("removing a linked account runs remove with its id", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  const linked = page.container.querySelector<HTMLElement>('[data-linked="acct-1"]')!;
  await act(async () => linked.querySelector<HTMLButtonElement>("button")!.click());
  await settle();
  expect(page.provider.accountRuns.at(-1)).toEqual({ action: "remove", provider: "codex", account: "acct-1" });
  expect(page.container.querySelector('[data-linked="acct-1"]')).toBeNull();
  page.unmount();
});

test("a pasted key is sent once, cleared, and a refusal shows in the form", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  const row = () => page.container.querySelector<HTMLElement>('[data-account="openrouter"]')!;
  await act(async () => row().querySelector<HTMLButtonElement>('[data-account-button="addKey"]')!.click());
  await settle();
  const field = () => row().querySelector<HTMLInputElement>('input[type="password"]')!;
  expect(row().querySelector<HTMLButtonElement>('[data-account-button="saveKeychain"]')!.disabled).toBe(true);
  await changeValue(field(), "bad");
  await act(async () => row().querySelector<HTMLButtonElement>('[data-account-button="saveKeychain"]')!.click());
  await settle();
  expect(page.provider.accountRuns.at(-1)).toEqual({ action: "saveKeychain", provider: "openrouter", secret: "bad" });
  expect(field().value).toBe("");
  expect(row().textContent).toContain("That is not a valid key");
  await changeValue(field(), "sk-good");
  await act(async () => row().querySelector<HTMLButtonElement>('[data-account-button="saveKeychain"]')!.click());
  await settle();
  expect(row().querySelector('input[type="password"]')).toBeNull();
  expect(row().textContent).toContain("Key found");
  expect(page.provider.accountRuns.filter((run) => run.secret === "sk-good").length).toBe(1);
  page.unmount();
});
