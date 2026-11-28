// Lawrence, msg 3790: "everywhere we say sign in, we need to have a button for signing in". Settings >
// Accounts' GitHub card, signed out ("Sign in to cmux to connect GitHub."), shows the shared Sign In
// button in place of Connect GitHub; it runs the Accounts sign-in. Signed in, Connect GitHub is back.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { GitHubConnectionState } from "./ops";
import { installDom } from "./testDom";
import { ACCOUNT_LISTS } from "../shared/signIn/galleryFixtures";
import type { ActiveSignIn } from "../shared/signIn/AccountSwitcher";
import { shouldShowGitHubSignIn } from "./components/GitHubAccountsCard";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const github: GitHubConnectionState = {
  title: "GitHub",
  detail: "Sign in to cmux to connect GitHub.",
  busy: false,
  connect: "Connect GitHub",
  disconnect: "Disconnect",
  confirm: "Disconnect GitHub?",
  cancel: "Cancel",
  refresh: "Refresh",
  canConnect: false,
  connections: [],
  signIn: "Sign In",
};

test("signed out, the GitHub card offers Sign In instead of Connect GitHub", async () => {
  const page = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = { ...provider.accounts, github };
    },
  });
  const card = page.container.querySelector<HTMLElement>('[data-card="github-connection"]')!;
  const button = card.querySelector<HTMLButtonElement>('[data-action="sign-in"]');
  expect(button?.textContent).toBe("Sign In");
  expect(card.querySelector('[data-github-action="connect"]')).toBeNull();
  await act(async () => button!.click());
  await settle();
  expect(page.provider.accountRuns.at(-1)).toMatchObject({ action: "signIn" });
  page.unmount();

  const signedIn = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = { ...provider.accounts, github: { ...github, signIn: null, canConnect: true } };
    },
  });
  const again = signedIn.container.querySelector<HTMLElement>('[data-card="github-connection"]')!;
  expect(again.querySelector('[data-action="sign-in"]')).toBeNull();
  expect(again.querySelector('[data-github-action="connect"]')).not.toBeNull();
  signedIn.unmount();
});

test("the App connection leads and the personal CLI login stays an explicit option", async () => {
  let release!: () => void;
  const page = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = {
        ...provider.accounts,
        github: { ...github, signIn: null, canConnect: true, busy: true, cliSignIn: "Use GitHub CLI" },
        signInAccounts: [...ACCOUNT_LISTS.oneEach],
      };
      provider.signInHold = new Promise<void>((resolve) => (release = resolve));
    },
  });
  const appCard = page.container.querySelector<HTMLElement>('[data-card="github-connection"]')!;
  const signInSection = page.container.querySelector<HTMLElement>('[data-card="account-sign-in"]')!;
  expect(appCard.compareDocumentPosition(signInSection) & Node.DOCUMENT_POSITION_FOLLOWING).not.toBe(0);
  expect(signInSection.querySelector('[data-sign-in-add="github"]')).toBeNull();
  const cli = appCard.querySelector<HTMLButtonElement>('[data-github-action="cli-sign-in"]')!;
  expect(cli.textContent).toBe("Use GitHub CLI");
  expect(cli.disabled).toBe(false);
  await act(async () => cli.click());
  await settle();
  expect(page.provider.accountRuns.at(-1)).toMatchObject({ action: "signInFinish" });
  expect(page.container.querySelectorAll(".signin").length).toBe(1);
  expect(appCard.querySelector(".signin")).toBeNull();
  expect(page.container.querySelector('[data-sign-in-account="github-2"] .signin')).not.toBeNull();
  release();
  await settle();
  page.unmount();
});

test("the personal CLI login falls back to a terminal on an older host", async () => {
  const page = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = { ...provider.accounts, github: { ...github, signIn: null, canConnect: true } };
    },
  });
  const appCard = page.container.querySelector<HTMLElement>('[data-card="github-connection"]')!;
  await act(async () => appCard.querySelector<HTMLButtonElement>('[data-github-action="cli-sign-in"]')!.click());
  await settle();
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "accountAdd", family: "github", way: "new" });
  expect(page.container.querySelector(".signin")).toBeNull();
  page.unmount();
});

test("a GitHub challenge stays visible while its new row is delayed", async () => {
  const running: ActiveSignIn = {
    family: "github",
    account: "github-2",
    view: {
      state: "waiting",
      way: { kind: "code", code: "WDJB-MJHT" },
      copied: true,
      url: "https://github.com/login/device",
    },
  };
  const rows = ACCOUNT_LISTS.oneEach;
  expect(shouldShowGitHubSignIn(running, rows)).toBe(true);
  expect(shouldShowGitHubSignIn(running, [...rows, { ...rows[0]!, id: "github-2", family: "github" }])).toBe(false);
});

// #46018: a connected GitHub in Settings can be disconnected and reconfigured (its installation's page
// on GitHub: which repositories, and the account or org access) from the connection's own row.
test("a connected GitHub row offers Reconfigure and Disconnect", async () => {
  const connected: GitHubConnectionState = {
    ...github,
    detail: "Connected",
    signIn: null,
    reconfigure: "Reconfigure",
    connections: [
      {
        id: "conn_1",
        account: "acme",
        status: "Connected",
        permissions: [],
        canDisconnect: true,
        canReconfigure: true,
      },
    ],
  };
  const page = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = { ...provider.accounts, github: connected };
    },
  });
  const row = page.container.querySelector<HTMLElement>('[data-github-connection="conn_1"]')!;
  const reconfigure = row.querySelector<HTMLButtonElement>('[data-github-action="reconfigure"]');
  expect(reconfigure?.textContent).toBe("Reconfigure");
  expect(row.querySelector('[data-github-action="disconnect"]')?.textContent).toBe("Disconnect");
  await act(async () => reconfigure!.click());
  await settle();
  expect(page.provider.accountRuns.at(-1)).toMatchObject({
    action: "githubReconfigure",
    account: "conn_1",
  });
  page.unmount();

  // A pending connection (or an older host without the title) has no Reconfigure.
  const pending = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = {
        ...provider.accounts,
        github: {
          ...connected,
          connections: [{ ...connected.connections[0]!, canReconfigure: false }],
        },
      };
    },
  });
  expect(pending.container.querySelector('[data-github-action="reconfigure"]')).toBeNull();
  pending.unmount();
});
