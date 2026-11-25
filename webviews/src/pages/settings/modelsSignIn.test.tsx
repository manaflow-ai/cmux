// Settings > Models' Claude login Sign In Again through the in-place sign-in card (logins done
// right; Leo, 2026-11-22: "this is simply logins, done righr."): on a host that lists the sign-in
// accounts the card opens under the row, on the CLI's own Claude login when it is signed out, else
// a new Claude account (as the host's `connectClaude` picks); a daemon without the in-place
// sign-in, or a host that does not list the accounts, keeps `connectClaude` (its terminal sign-in).
import { afterAll, afterEach, expect, test } from "bun:test";
import { mockModels } from "./mockModels";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";
import { ACCOUNT_LISTS } from "../shared/signIn/galleryFixtures";
import type { AccountRowWire } from "../shared/signIn/accountSignIn";

const restore = installDom();
afterAll(() => restore());
const { renderPage, click, settle, changeValue } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const claudeSignedOut: AccountRowWire[] = ACCOUNT_LISTS.signedOut.map((row) =>
  row.family === "claude" ? { ...row, signedIn: false } : row,
);

async function open(options: { accounts?: AccountRowWire[] | null; olderDaemon?: boolean; held?: boolean } = {}) {
  page = await renderPage({
    path: "/settings/models",
    setup: (provider) => {
      provider.models = structuredClone(mockModels.macLogins);
      if (options.accounts !== null) {
        provider.accounts = {
          ...provider.accounts,
          signInAccounts: [...(options.accounts ?? ACCOUNT_LISTS.signedOut)],
        };
      }
      provider.signIn.olderDaemon = options.olderDaemon === true;
      if (options.held !== false) provider.signInHold = new Promise<void>(() => {});
    },
  });
  await settle();
  return page;
}

async function signInAgain(rendered: Rendered) {
  await click(rendered.container.querySelector('[data-menu="connection-claude-login"]')!);
  await click(document.querySelector<HTMLElement>('[role="menuitem"][data-value="signInAgain"]')!);
  await settle();
}

const card = (rendered: Rendered) =>
  rendered.container.querySelector<HTMLElement>('[data-connection-sign-in="claude-login"] .signin');

test("Sign In Again on a signed-out Claude login signs that login in, in place", async () => {
  const rendered = await open({ accounts: claudeSignedOut });
  await signInAgain(rendered);
  expect(card(rendered)?.dataset.state).toBe("waiting");
  expect(rendered.provider.accountRuns.find((run) => run.action === "signInStart")).toMatchObject({
    family: "claude",
    account: "claude-1",
  });
  expect(rendered.provider.modelRuns.some((run) => run.action === "connectClaude")).toBe(false);
});

test("Sign In Again with the CLI's login signed in adds a new Claude account, in place", async () => {
  const rendered = await open();
  await signInAgain(rendered);
  expect(card(rendered)?.dataset.state).toBe("waiting");
  const start = rendered.provider.accountRuns.find((run) => run.action === "signInStart");
  expect(start).toMatchObject({ family: "claude" });
  expect(start?.account).toBeUndefined();
  expect(rendered.provider.modelRuns.some((run) => run.action === "connectClaude")).toBe(false);
});

test("a daemon without the in-place sign-in, or a host without the accounts, keeps connectClaude", async () => {
  for (const options of [{ olderDaemon: true }, { accounts: null }]) {
    const rendered = await open(options);
    await signInAgain(rendered);
    expect(rendered.provider.modelRuns.filter((run) => run.action === "connectClaude")).toEqual([
      { action: "connectClaude" },
    ]);
    expect(card(rendered)).toBeNull();
    rendered.unmount();
    page = null;
  }
});

test("a finished in-place sign-in reads Models again, so the row shows it", async () => {
  const rendered = await open({ accounts: claudeSignedOut, held: false });
  await signInAgain(rendered);
  // The host's Models changed with the sign-in but sent no change: only a fresh read shows it.
  const models = structuredClone(mockModels.macLogins);
  const own = models.personal!.connections.find((connection) => connection.id === "claude-login")!;
  own.email = "signed-in@example.com";
  rendered.provider.models = models;
  const form = rendered.container.querySelector<HTMLElement>('[data-connection-sign-in="claude-login"] .signin')!;
  await changeValue(form.querySelector<HTMLInputElement>("input")!, "pasted-code");
  await click(form.querySelector<HTMLElement>('[data-sign-in-action="continue"]')!);
  await settle();
  expect(card(rendered)?.dataset.state).toBe("signedIn");
  expect(
    rendered.container.querySelector('[data-card="models"] [data-connection="claude-login"]')?.textContent,
  ).toContain("signed-in@example.com");
});
