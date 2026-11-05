// Agents > Harnesses accounts (acpmux `_acpmux/accounts`): a provider row says whose login it uses
// and its plan, lists every account routing may use with its switch, Add account makes a Codex
// shadow home and its sign-in, and a daemon without accounts keeps today's card.
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
  // Claude lists its login, signed out with a Sign In, and has no Add account.
  const claude = card(page.container).querySelector<HTMLElement>('[data-harness="claude"]')!;
  expect(claude.querySelector("[data-harness-account-auth]")?.textContent).toBe("Not signed in");
  expect(claude.querySelector('[data-account="claude-login"] [data-account-action="signIn"]')).not.toBeNull();
  expect(claude.querySelector('[data-account-action="add"]')).toBeNull();
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
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountAdd", family: "codex" });
  const added = codex().querySelector<HTMLElement>('[data-account="codex-3"]')!;
  expect(added.textContent).toContain("ChatGPT 3");
  expect(added.querySelector("[data-account-auth]")?.textContent).toBe("Not signed in");
  await act(async () => added.querySelector<HTMLButtonElement>('[data-account-action="signIn"]')!.click());
  await settle();
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountSignIn", account: "codex-3" });
  page.unmount();
});

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
