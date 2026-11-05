// Agents > Harnesses accounts (acpmux `_acpmux/accounts`): a provider row says whose login it uses
// and its plan, lists every account routing may use with its switch, Add account (Codex and Claude)
// makes a login folder and its sign-in or an API-key account, each row offers Make Default, Rename,
// Sign In / Sign Out and Remove, and a daemon without accounts keeps today's card.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { agoText, planName } from "./harnesses";
import type { HarnessesState, ProviderAccount } from "./ops";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="harnesses"]')!;

const accounts: ProviderAccount[] = [
  {
    id: "codex-login",
    family: "codex",
    name: "ChatGPT",
    home: null,
    defaultHome: "~/.codex",
    shadowOf: null,
    signedIn: true,
    plan: "pro",
    email: "alex@example.com",
    enabled: true,
    builtin: true,
    default: true,
  },
  {
    id: "codex-2",
    family: "codex",
    name: "ChatGPT 2",
    home: "~/.cmux/accounts/codex-2",
    defaultHome: "~/.codex",
    shadowOf: "codex-login",
    signedIn: true,
    plan: "plus",
    email: "sam@example.com",
    enabled: false,
    builtin: false,
  },
  {
    id: "claude-login",
    family: "claude",
    name: "Claude",
    home: null,
    defaultHome: "~/.claude",
    shadowOf: null,
    signedIn: false,
    plan: null,
    email: null,
    enabled: true,
    builtin: true,
  },
];

async function withAccounts(extra: Partial<HarnessesState> = {}) {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  await act(async () => page.provider.setHarnesses({ ...page.provider.harnesses, accounts, ...extra }));
  await settle();
  return page;
}

test("a provider row says whose login it uses and its plan; each account shows who, plan, folder and its switch", async () => {
  const page = await withAccounts();
  const codex = card(page.container).querySelector<HTMLElement>('[data-harness="codex"]')!;
  expect(codex.querySelector("[data-harness-account-auth]")?.textContent).toBe("Authenticated · ChatGPT Pro");
  const rows = [...codex.querySelectorAll<HTMLElement>("[data-account]")];
  expect(rows.map((row) => row.dataset.account)).toEqual(["codex-login", "codex-2"]);
  expect(rows[0]!.querySelector("[data-account-auth]")?.textContent).toBe(
    "Authenticated as alex@example.com · ChatGPT Pro",
  );
  expect(rows[0]!.querySelector("[data-account-folder]")?.textContent).toBe("Login folder ~/.codex");
  // A shadow home names the folder whose settings and chats it shares (here by the account's id).
  expect(rows[1]!.querySelector("[data-account-folder]")?.textContent).toBe(
    "~/.cmux/accounts/codex-2 · Shares settings and chats with ~/.codex",
  );
  expect(rows[1]!.querySelector('[role="switch"]')?.getAttribute("aria-checked")).toBe("false");
  expect(codex.querySelector('[data-account-action="add"]')).not.toBeNull();
  // The default says so and offers no Make Default; the other does, and only an added one is removable.
  expect(rows[0]!.querySelector("[data-account-default]")?.textContent).toBe("Default");
  expect(rows[0]!.querySelector('[data-account-action="default"]')).toBeNull();
  expect(rows[0]!.querySelector('[data-account-action="remove"]')).toBeNull();
  expect(rows[1]!.querySelector('[data-account-action="default"]')).not.toBeNull();
  expect(rows[1]!.querySelector('[data-account-action="remove"]')).not.toBeNull();
  // Signed in: Sign Out, not Sign In.
  expect(rows[1]!.querySelector('[data-account-action="signOut"]')).not.toBeNull();
  expect(rows[1]!.querySelector('[data-account-action="signIn"]')).toBeNull();
  // Claude lists its login, signed out with a Sign In and no Rename (acpmux keeps no file for it),
  // and has Add account too.
  const claude = card(page.container).querySelector<HTMLElement>('[data-harness="claude"]')!;
  expect(claude.querySelector("[data-harness-account-auth]")?.textContent).toBe("Not signed in");
  expect(claude.querySelector('[data-account="claude-login"] [data-account-action="signIn"]')).not.toBeNull();
  expect(claude.querySelector('[data-account="claude-login"] [data-account-action="rename"]')).toBeNull();
  expect(claude.querySelector('[data-account-action="add"]')).not.toBeNull();
  // A harness of no account family lists none.
  expect(card(page.container).querySelector('[data-harness="aider"] [data-harness-accounts]')).toBeNull();
  page.unmount();
});

test("the switch asks the host to let routing use the account, and Add account then Sign In run for Codex", async () => {
  const page = await withAccounts();
  const codex = () => card(page.container).querySelector<HTMLElement>('[data-harness="codex"]')!;
  await act(async () => codex().querySelector<HTMLElement>('[data-account="codex-2"] [role="switch"]')!.click());
  await settle();
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountEnable", account: "codex-2", on: true });
  expect(codex().querySelector('[data-account="codex-2"] [role="switch"]')?.getAttribute("aria-checked")).toBe("true");
  await act(async () => codex().querySelector<HTMLButtonElement>('[data-account-action="add"]')!.click());
  await settle();
  await act(async () => codex().querySelector<HTMLButtonElement>('[data-account-action="addConfirm"]')!.click());
  await settle();
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountAdd", family: "codex", way: "new" });
  expect(codex().querySelector("[data-account-add]")).toBeNull();
  const added = codex().querySelector<HTMLElement>('[data-account="codex-3"]')!;
  expect(added.textContent).toContain("ChatGPT 3");
  expect(added.querySelector("[data-account-auth]")?.textContent).toBe("Not signed in");
  await act(async () => added.querySelector<HTMLButtonElement>('[data-account-action="signIn"]')!.click());
  await settle();
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountSignIn", account: "codex-3" });
  page.unmount();
});

test("Claude's Add account takes an API key by its reference, with the name typed", async () => {
  const page = await withAccounts();
  const claude = () => card(page.container).querySelector<HTMLElement>('[data-harness="claude"]')!;
  await act(async () => claude().querySelector<HTMLButtonElement>('[data-account-action="add"]')!.click());
  await settle();
  const form = claude().querySelector<HTMLElement>('[data-account-add="claude"]')!;
  const select = form.querySelector<HTMLSelectElement>("select")!;
  expect([...select.options].map((option) => option.textContent)).toEqual([
    "Sign in with a new Claude login",
    "Use an API key",
  ]);
  await act(async () => {
    select.value = "key";
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await settle();
  const confirm = () => claude().querySelector<HTMLButtonElement>('[data-account-action="addConfirm"]')!;
  expect(confirm().disabled).toBe(true);
  const [name, secret] = [...claude().querySelectorAll<HTMLInputElement>("[data-account-add] input")];
  await act(async () => {
    typeInto(name!, "Work key");
    typeInto(secret!, "keychain:anthropic-work");
  });
  await settle();
  await act(async () => confirm().click());
  await settle();
  expect(page.provider.harnessRuns.at(-1)).toEqual({
    action: "accountAdd",
    family: "claude",
    way: "key",
    name: "Work key",
    secret: "keychain:anthropic-work",
  });
  const added = claude().querySelector<HTMLElement>('[data-account="claude-2"]')!;
  expect(added.querySelector("[data-account-auth]")?.textContent).toBe("Authenticated · API key");
  expect(added.querySelector("[data-account-folder]")).toBeNull();
  expect(added.querySelector('[data-account-action="signOut"]')).toBeNull();
  page.unmount();
});

test("Make Default, Rename, Sign Out and Remove each ask the host for their account", async () => {
  const page = await withAccounts();
  const row = () => card(page.container).querySelector<HTMLElement>('[data-account="codex-2"]')!;
  const press = async (action: string) => {
    await act(async () => row().querySelector<HTMLButtonElement>(`[data-account-action="${action}"]`)!.click());
    await settle();
  };
  await press("default");
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountDefault", account: "codex-2" });
  expect(row().querySelector("[data-account-default]")).not.toBeNull();
  await press("rename");
  const input = row().querySelector<HTMLInputElement>("[data-account-rename] input")!;
  expect(input.value).toBe("ChatGPT 2");
  await act(async () => typeInto(input, "Work"));
  await act(async () => row().querySelector<HTMLFormElement>("[data-account-rename]")!.requestSubmit());
  await settle();
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountRename", account: "codex-2", name: "Work" });
  expect(row().querySelector(".harness-account-name")?.textContent).toContain("Work");
  await press("signOut");
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountSignOut", account: "codex-2" });
  await press("remove");
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountRemove", account: "codex-2" });
  expect(card(page.container).querySelector('[data-account="codex-2"]')).toBeNull();
  page.unmount();
});

/** Sets a controlled input's value the way typing does (React tracks the native setter). */
function typeInto(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

test("a daemon without accounts keeps today's card: no account lines, lists or Add account", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  expect(page.provider.harnesses.accounts).toBeUndefined();
  expect(card(page.container).querySelector("[data-harness-account-auth]")).toBeNull();
  expect(card(page.container).querySelector("[data-harness-accounts]")).toBeNull();
  expect(card(page.container).querySelector("[data-harnesses-checked]")).toBeNull();
  page.unmount();
});

test("the header says when acpmux last checked", async () => {
  const page = await withAccounts({
    harnesses: page0().map((row, index) => ({ ...row, checkedAt: Date.now() - (index + 54) * 60_000 })),
  });
  expect(card(page.container).querySelector("[data-harnesses-checked]")?.textContent).toMatch(/^Checked 54 min/);
  page.unmount();
});

test("plans read as their product names, other text as given; under a minute is just now", () => {
  expect(planName("codex", "pro")).toBe("ChatGPT Pro");
  expect(planName("claude", "max")).toBe("Claude Max");
  expect(planName("codex", "ChatGPT Pro 20x")).toBe("ChatGPT Pro 20x");
  expect(planName("codex", null)).toBeNull();
  expect(agoText(1_000_000, 1_030_000, "en")).toBeNull();
  expect(agoText(0, 3 * 3_600_000, "en")).toBe("3 hr. ago");
});

function page0(): HarnessesState["harnesses"] {
  return [
    { id: "claude", name: null, kind: "claude-stdio", source: "path", problem: null },
    { id: "codex", name: null, kind: "acp", source: "path", problem: null },
  ];
}
