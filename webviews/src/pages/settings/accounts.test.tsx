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

test("the active team is one menu row; choosing another team runs selectTeam and moves the check", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  const section = () => page.container.querySelector<HTMLElement>("[data-accounts-teams]")!;
  const button = () => section().querySelector<HTMLButtonElement>(".ui-select-button")!;
  const native = () => section().querySelector<HTMLSelectElement>("select.ui-select-native")!;
  // One row, not a row per team: the label, then a pop-up button showing the active team.
  expect(section().querySelectorAll(".row").length).toBe(1);
  expect(section().querySelector(".row-title")?.textContent).toBe("Active Team");
  expect(section().querySelector('input[type="radio"]')).toBeNull();
  expect(button().textContent).toBe("Personal");
  expect(button().getAttribute("aria-haspopup")).toBe("menu");
  expect(button().getAttribute("aria-labelledby")).toBe(section().querySelector(".row-title")!.id);
  expect(button().disabled).toBe(false);
  // Opening it lists every team, the active one checked.
  await act(async () => button().click());
  await settle();
  const items = [...document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')];
  expect(items.map((item) => item.textContent?.replace("✓", "").trim())).toEqual(["Personal", "Acme"]);
  expect(items.map((item) => item.getAttribute("aria-checked"))).toEqual(["true", "false"]);
  await act(async () => items[1]!.click());
  await settle();
  expect(page.provider.accountRuns.at(-1)).toEqual({ action: "selectTeam", team: "team-acme" });
  expect(button().textContent).toBe("Acme");
  expect(native().value).toBe("team-acme");
  page.unmount();
});

test("a managed device or a single team shows the menu disabled; signed out shows no team row", async () => {
  const managed = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = {
        ...provider.accounts,
        teams: { ...provider.accounts.teams!, disabled: true, note: "Your organization chose this device's team." },
      };
    },
  });
  const managedSection = managed.container.querySelector<HTMLElement>("[data-accounts-teams]")!;
  expect(managedSection.querySelector<HTMLButtonElement>(".ui-select-button")!.disabled).toBe(true);
  expect(managedSection.textContent).toContain("Your organization chose this device's team.");
  managed.unmount();
  const single = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = {
        ...provider.accounts,
        teams: { ...provider.accounts.teams!, options: [{ id: "team-personal", name: "Personal", active: true }] },
      };
    },
  });
  const only = single.container.querySelector<HTMLButtonElement>("[data-accounts-teams] .ui-select-button")!;
  expect(only.textContent).toBe("Personal");
  expect(only.disabled).toBe(true);
  single.unmount();
  const signedOut = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = { ...provider.accounts, teams: null };
    },
  });
  expect(signedOut.container.querySelector("[data-accounts-teams]")).toBeNull();
  signedOut.unmount();
});
