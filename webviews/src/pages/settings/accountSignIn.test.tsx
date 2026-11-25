// Settings > Accounts' in-place sign-in (logins done right): one click starts it, the code shows in
// the row and the row turns into the account by itself; an expired code offers New code; the code
// never reaches the store, a log or a data attribute.
import { act } from "react";
import { afterAll, expect, spyOn, test } from "bun:test";
import { installDom } from "./testDom";
import { ACCOUNT_LISTS } from "../shared/signIn/galleryFixtures";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const GITHUB_CODE = "WDJB-MJHT";

/** Every attribute value in `root`, so a test can say the code is in none of them. */
function attributeValues(root: Element): string[] {
  return [root, ...root.querySelectorAll("*")].flatMap((node) => [...node.attributes].map((attr) => attr.value));
}

async function open(setup?: NonNullable<Parameters<typeof renderPage>[0]>["setup"]) {
  return renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = { ...provider.accounts, signInAccounts: [...ACCOUNT_LISTS.oneEach] };
      setup?.(provider);
    },
  });
}

test("an older host (no signInAccounts) draws no in-place sign-in", async () => {
  const page = await renderPage({ path: "/settings/accounts" });
  expect(page.container.querySelector('[data-card="account-sign-in"]')).toBeNull();
  page.unmount();
});

test("Add account shows the code in place, waits, and turns into the account by itself", async () => {
  let release!: () => void;
  const logs: unknown[][] = [];
  const spies = (["log", "info", "warn", "error", "debug"] as const).map((level) =>
    spyOn(console, level).mockImplementation((...args: unknown[]) => void logs.push(args)),
  );
  const page = await open((provider) => {
    provider.signInHold = new Promise<void>((resolve) => (release = resolve));
  });
  const section = () => page.container.querySelector<HTMLElement>('[data-card="account-sign-in"]')!;
  const add = section().querySelector<HTMLButtonElement>(
    '[data-sign-in-add="github"] [data-sign-in-row-action="add"]',
  )!;
  await act(async () => add.click());
  await settle();
  const card = () => section().querySelector<HTMLElement>(".signin")!;
  expect(card().dataset.state).toBe("waiting");
  expect(card().textContent).toContain(GITHUB_CODE);
  expect(card().querySelector('[data-sign-in-action="copy"]')).not.toBeNull();
  expect(page.provider.accountRuns.map((run) => run.action)).toEqual(
    expect.arrayContaining(["signInStart", "signInFinish"]),
  );
  // The code is visible text only: no attribute, store state or log carries it.
  expect(attributeValues(page.container).some((value) => value.includes(GITHUB_CODE))).toBe(false);
  expect(JSON.stringify(page.store.getSnapshot())).not.toContain(GITHUB_CODE);
  expect(JSON.stringify(logs)).not.toContain(GITHUB_CODE);
  await act(async () => release());
  await settle();
  expect(card().dataset.state).toBe("signedIn");
  expect(card().textContent).toContain("Signed in as octocat");
  expect(section().querySelector('[data-sign-in-account="github-2"]')?.textContent).toContain("octocat");
  expect(JSON.stringify(logs)).not.toContain(GITHUB_CODE);
  for (const spy of spies) spy.mockRestore();
  page.unmount();
});

test("a code that runs out shows New code, which starts a fresh sign-in", async () => {
  const page = await open((provider) => {
    provider.signInHold = new Promise<void>(() => {});
    provider.signInExpiresInMs = 30;
  });
  const section = () => page.container.querySelector<HTMLElement>('[data-card="account-sign-in"]')!;
  await act(async () =>
    section().querySelector<HTMLButtonElement>('[data-sign-in-add="codex"] [data-sign-in-row-action="add"]')!.click(),
  );
  await settle();
  const card = () => section().querySelector<HTMLElement>(".signin")!;
  // The code runs out 30 ms after the start answers, whenever that is on a busy machine: wait for
  // the card to say so (2 s at most), never a fixed time measured from the click.
  for (const deadline = Date.now() + 2000; card()?.dataset.state !== "expired" && Date.now() < deadline;) {
    // fixed-wait: one 20 ms poll step of the bounded wait above, not the wait itself.
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 20)));
    await settle();
  }
  expect(card().dataset.state).toBe("expired");
  expect(card().textContent).not.toContain("K7QX-29PF");
  const actions = [...card().querySelectorAll<HTMLElement>("[data-sign-in-action]")].map(
    (node) => node.dataset.signInAction,
  );
  expect(actions).toEqual(["newCode"]);
  expect(page.provider.accountRuns.some((run) => run.action === "signInCancel")).toBe(true);
  const starts = page.provider.accountRuns.filter((run) => run.action === "signInStart").length;
  // The fresh code lasts: at 30 ms it could run out again before the card is read.
  page.provider.signInExpiresInMs = 60_000;
  await act(async () => card().querySelector<HTMLButtonElement>('[data-sign-in-action="newCode"]')!.click());
  await settle();
  expect(page.provider.accountRuns.filter((run) => run.action === "signInStart").length).toBe(starts + 1);
  expect(card().dataset.state).toBe("waiting");
  page.unmount();
});

test("a refusal shows its reason and one recovery action", async () => {
  const page = await open((provider) => {
    provider.signInRefusal = "shared_machine";
  });
  const section = () => page.container.querySelector<HTMLElement>('[data-card="account-sign-in"]')!;
  await act(async () =>
    section().querySelector<HTMLButtonElement>('[data-sign-in-add="claude"] [data-sign-in-row-action="add"]')!.click(),
  );
  await settle();
  const card = section().querySelector<HTMLElement>(".signin")!;
  expect(card.textContent).toContain("shared team machine");
  expect(
    [...card.querySelectorAll<HTMLElement>("[data-sign-in-action]")].map((node) => node.dataset.signInAction),
  ).toEqual(["done"]);
  page.unmount();
});

test("Claude's pasted code is sent once with finish and cleared", async () => {
  const page = await open();
  const section = () => page.container.querySelector<HTMLElement>('[data-card="account-sign-in"]')!;
  await act(async () =>
    section().querySelector<HTMLButtonElement>('[data-sign-in-add="claude"] [data-sign-in-row-action="add"]')!.click(),
  );
  await settle();
  const field = section().querySelector<HTMLInputElement>(".signin-paste-field")!;
  const { changeValue } = await import("./testing");
  await changeValue(field, "pasted-secret-code");
  await act(async () => section().querySelector<HTMLButtonElement>('[data-sign-in-action="continue"]')!.click());
  await settle();
  const finishes = page.provider.accountRuns.filter((run) => run.action === "signInFinish");
  expect(finishes.length).toBe(1);
  expect(finishes[0]!.code).toBe("pasted-secret-code");
  expect(section().querySelector(".signin")?.getAttribute("data-state")).toBe("signedIn");
  expect(attributeValues(page.container).some((value) => value.includes("pasted-secret-code"))).toBe(false);
  page.unmount();
});

test("Use, Sign out and Remove run their gestures on the row", async () => {
  const page = await open((provider) => {
    provider.accounts = { ...provider.accounts, signInAccounts: [...ACCOUNT_LISTS.twoEach] };
  });
  const row = (id: string) => page.container.querySelector<HTMLElement>(`[data-sign-in-account="${id}"]`);
  await act(async () => row("codex-2")!.querySelector<HTMLButtonElement>('[data-sign-in-row-action="use"]')!.click());
  await settle();
  expect(page.provider.accountRuns.at(-1)).toEqual({ action: "accountSwitch", account: "codex-2", provider: "codex" });
  expect(row("codex-2")!.querySelector("[data-sign-in-default]")).not.toBeNull();
  await act(async () =>
    row("claude-2")!.querySelector<HTMLButtonElement>('[data-sign-in-row-action="signOut"]')!.click(),
  );
  await settle();
  expect(row("claude-2")!.textContent).toContain("Signed out");
  await act(async () =>
    row("github-2")!.querySelector<HTMLButtonElement>('[data-sign-in-row-action="remove"]')!.click(),
  );
  await settle();
  expect(row("github-2")).toBeNull();
  page.unmount();
});

test("GitHub's Add account on a daemon without the in-place sign-in types gh's own login in a terminal", async () => {
  const page = await open((provider) => {
    provider.signIn.olderDaemon = true;
  });
  const section = () => page.container.querySelector<HTMLElement>('[data-card="account-sign-in"]')!;
  await act(async () =>
    section().querySelector<HTMLButtonElement>('[data-sign-in-add="github"] [data-sign-in-row-action="add"]')!.click(),
  );
  await settle();
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountAdd", family: "github", way: "new" });
  expect(section().querySelector(".signin")).toBeNull();
  page.unmount();
});
