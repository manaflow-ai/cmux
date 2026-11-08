// Lawrence, msg 3790: "everywhere we say sign in, we need to have a button for signing in". Settings >
// Accounts' GitHub card, signed out ("Sign in to cmux to connect GitHub."), shows the shared Sign In
// button in place of Connect GitHub; it runs the Accounts sign-in. Signed in, Connect GitHub is back.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { GitHubConnectionState } from "./ops";
import { installDom } from "./testDom";

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
