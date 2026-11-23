// Agents > Harnesses' Sign In, an account's Sign In and a new login's Add account through the
// in-place sign-in card (logins done right; Leo, 2026-11-22: "this is simply logins, done righr."):
// on a host that lists the sign-in accounts the card shows the code under the row, with no
// terminal tab; a daemon without `_acpmux/account/sign_in` gets the same terminal gesture as
// before; a host that does not list them keeps the terminal path (harnessesCard.test.tsx,
// providerAccounts.test.tsx). The code is the card's visible text only.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { HarnessesState, ProviderAccount } from "./ops";
import { ACCOUNT_LISTS } from "../shared/signIn/galleryFixtures";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const CODEX_CODE = "K7QX-29PF";

const accounts: ProviderAccount[] = [
  {
    id: "codex-1",
    family: "codex",
    name: "ChatGPT",
    home: null,
    defaultHome: "~/.codex",
    shadowOf: null,
    signedIn: false,
    plan: null,
    email: null,
    enabled: true,
    builtin: true,
    default: true,
  },
];

function attributeValues(root: Element): string[] {
  return [root, ...root.querySelectorAll("*")].flatMap((node) => [...node.attributes].map((attr) => attr.value));
}

function typeInto(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

async function open(options: { inPlace?: boolean; olderDaemon?: boolean; extra?: Partial<HarnessesState> } = {}) {
  const page = await renderPage({
    path: "/settings/agents",
    setup: (provider) => {
      if (options.inPlace !== false) {
        provider.accounts = { ...provider.accounts, signInAccounts: [...ACCOUNT_LISTS.signedOut] };
      }
      provider.signIn.olderDaemon = options.olderDaemon === true;
      provider.signInHold = new Promise<void>(() => {});
    },
  });
  await settle();
  await act(async () => page.provider.setHarnesses({ ...page.provider.harnesses, accounts, ...options.extra }));
  await settle();
  return page;
}

const codex = (container: HTMLElement) =>
  container.querySelector<HTMLElement>('[data-card="harnesses"] [data-harness="codex"]')!;

test("a harness's Sign In shows the code in place under its row, with no terminal tab", async () => {
  const page = await open();
  await act(async () =>
    codex(page.container).querySelector<HTMLButtonElement>('[data-harness-action="signIn"]')!.click(),
  );
  await settle();
  const card = codex(page.container).querySelector<HTMLElement>('[data-harness-sign-in="codex"] .signin')!;
  expect(card.dataset.state).toBe("waiting");
  expect(card.textContent).toContain(CODEX_CODE);
  expect(page.provider.accountRuns.find((run) => run.action === "signInStart")).toMatchObject({
    account: "codex-1",
    family: "codex",
  });
  expect(page.provider.harnessRuns.some((run) => run.action === "signIn")).toBe(false);
  expect(attributeValues(page.container).some((value) => value.includes(CODEX_CODE))).toBe(false);
  expect(JSON.stringify(page.store.getSnapshot())).not.toContain(CODEX_CODE);
  page.unmount();
});

test("a daemon without the in-place sign-in gets the harness's terminal sign-in", async () => {
  const page = await open({ olderDaemon: true });
  await act(async () =>
    codex(page.container).querySelector<HTMLButtonElement>('[data-harness-action="signIn"]')!.click(),
  );
  await settle();
  expect(page.provider.harnessRuns.filter((run) => run.action === "signIn")).toEqual([
    { action: "signIn", id: "codex" },
  ]);
  expect(codex(page.container).querySelector("[data-harness-sign-in]")).toBeNull();
  page.unmount();
});

test("a host that does not list sign-in accounts keeps the terminal sign-in", async () => {
  const page = await open({ inPlace: false });
  await act(async () =>
    codex(page.container).querySelector<HTMLButtonElement>('[data-harness-action="signIn"]')!.click(),
  );
  await settle();
  expect(page.provider.accountRuns.some((run) => run.action === "signInStart")).toBe(false);
  expect(page.provider.harnessRuns.filter((run) => run.action === "signIn")).toEqual([
    { action: "signIn", id: "codex" },
  ]);
  page.unmount();
});

test("an account's Sign In signs that account in, in place", async () => {
  const page = await open();
  await act(async () =>
    codex(page.container)
      .querySelector<HTMLButtonElement>('[data-account="codex-1"] [data-account-action="signIn"]')!
      .click(),
  );
  await settle();
  expect(codex(page.container).querySelector<HTMLElement>("[data-harness-sign-in] .signin")?.dataset.state).toBe(
    "waiting",
  );
  expect(page.provider.accountRuns.find((run) => run.action === "signInStart")).toMatchObject({ account: "codex-1" });
  expect(page.provider.harnessRuns.some((run) => run.action === "accountSignIn")).toBe(false);
  page.unmount();
});

test("Add account's new login signs in in place with the typed name; an older daemon types it in a terminal", async () => {
  for (const olderDaemon of [false, true]) {
    const page = await open({ olderDaemon });
    const row = () => codex(page.container);
    await act(async () => row().querySelector<HTMLButtonElement>('[data-account-action="add"]')!.click());
    await settle();
    const name = row().querySelector<HTMLInputElement>("[data-account-add] input")!;
    await act(async () => typeInto(name, "Work"));
    await settle();
    await act(async () => row().querySelector<HTMLButtonElement>('[data-account-action="addConfirm"]')!.click());
    await settle();
    expect(row().querySelector("[data-account-add]")).toBeNull();
    const start = page.provider.accountRuns.find((run) => run.action === "signInStart");
    expect(start).toMatchObject({ family: "codex", name: "Work" });
    expect(start?.account).toBeUndefined();
    if (olderDaemon) {
      expect(page.provider.harnessRuns.at(-1)).toEqual({
        action: "accountAdd",
        family: "codex",
        way: "new",
        name: "Work",
      });
    } else {
      expect(row().querySelector<HTMLElement>("[data-harness-sign-in] .signin")?.dataset.state).toBe("waiting");
      expect(page.provider.harnessRuns.some((run) => run.action === "accountAdd")).toBe(false);
    }
    page.unmount();
  }
});

test("Cancel while a harness Sign In is starting opens no terminal, on either daemon", async () => {
  for (const olderDaemon of [false, true]) {
    let answer = () => {};
    const page = await open({ olderDaemon });
    page.provider.signIn.startHold = new Promise<void>((resolve) => (answer = resolve));
    await act(async () =>
      codex(page.container).querySelector<HTMLButtonElement>('[data-harness-action="signIn"]')!.click(),
    );
    await settle();
    const card = codex(page.container).querySelector<HTMLElement>("[data-harness-sign-in] .signin")!;
    expect(card.dataset.state).toBe("starting");
    await act(async () => card.querySelector<HTMLButtonElement>('[data-sign-in-action="cancel"]')!.click());
    await act(async () => answer());
    await settle();
    expect(codex(page.container).querySelector("[data-harness-sign-in]")).toBeNull();
    expect(page.provider.harnessRuns.some((run) => run.action === "signIn")).toBe(false);
    // A new daemon's login that answered after the Cancel is cancelled too.
    if (!olderDaemon) expect(page.provider.signIn.cancelled).toEqual(["login-1"]);
    page.unmount();
  }
});

test("a double click on Sign In starts one sign-in", async () => {
  const page = await open();
  let answer = () => {};
  page.provider.signIn.startHold = new Promise<void>((resolve) => (answer = resolve));
  const button = codex(page.container).querySelector<HTMLButtonElement>('[data-harness-action="signIn"]')!;
  await act(async () => {
    button.click();
    button.click();
  });
  await act(async () => answer());
  await settle();
  expect(page.provider.signIn.starts).toBe(1);
  expect(codex(page.container).querySelector<HTMLElement>("[data-harness-sign-in] .signin")?.dataset.state).toBe(
    "waiting",
  );
  page.unmount();
});
