// Every Settings "Sign in" through the one in-place sign-in card (logins done right). Leo,
// 2026-11-22: "we likewise want gh auth or device stuff to be much more convienient ui/ux wise ...
// we want that for anywhere and everywhere we have codex stuff, and extremely convieniently tightly
// integrated claude stuff ... this is simply logins, done righr." Settings > Accounts, Agents >
// Harnesses' Sign In and an account's Add account / Sign In all start the daemon's sign-in through
// the host (`cmux.settings.accounts.run`, shared/signIn ACCOUNT_ACTIONS); the host opens the
// provider's page beside the window and the card shows the code.
// `inPlace` is the host saying it signs in in place: it lists the sign-in accounts
// (`accounts.signInAccounts`). Without it a caller keeps its terminal gesture. A host whose daemon
// has no `_acpmux/account/sign_in` runs the start's terminal sign-in itself inside the same call
// (`terminal`, while the click still counts as the person's); an older host that answers without a
// sign-in gets the gesture's own terminal fallback, the one the caller passed with that start.
import { useMemo, useRef } from "react";
import { useSettingsState, useStore } from "../context";
import type { HarnessesRun } from "../ops";
import { ACCOUNT_ACTIONS, type AccountFamily, type AccountRunParams } from "../../shared/signIn/accountSignIn";
import {
  useAccountSignIn,
  type AccountSignInController,
  type AccountSignInTransport,
} from "../../shared/signIn/useAccountSignIn";

export type SettingsSignIn = AccountSignInController & {
  /** The host signs in in place (it lists `accounts.signInAccounts`). */
  inPlace: boolean;
  /** Starts the card's sign-in; `fallback` is this gesture's terminal sign-in for an older daemon. */
  begin(family: AccountFamily, account: string | null, fallback: () => void, name?: string): void;
};

/** `onSignedIn`: after a sign-in finished (a harness row reads its health again). */
export function useSettingsSignIn(onSignedIn?: () => void): SettingsSignIn {
  const store = useStore();
  const listed = useSettingsState().accounts?.signInAccounts;
  const signedIn = useRef(onSignedIn);
  signedIn.current = onSignedIn;
  const transport = useMemo<AccountSignInTransport>(
    () => ({
      run: async (params: AccountRunParams) => {
        const reply = await store.runAccountSignIn(params);
        if (params.action === ACCOUNT_ACTIONS.finish && reply.ok && reply.value.finished?.signedIn)
          signedIn.current?.();
        return reply;
      },
    }),
    [store],
  );
  const signIn = useAccountSignIn(transport);
  return {
    ...signIn,
    inPlace: Array.isArray(listed),
    begin: (family, account, terminal, name) => signIn.start(family, account, name, terminal),
  };
}

/** The terminal sign-in an older daemon (no `_acpmux/account/sign_in`) gets, as Agents > Harnesses
 * runs it: the account's own login, a new one's (with its typed name), or gh's own `gh auth login`
 * for GitHub (before, GitHub's Add account did nothing there). */
export function terminalSignIn(family: AccountFamily, account: string | null, name?: string): HarnessesRun {
  if (family === "github") return { action: "accountAdd", family, way: "new" };
  if (account) return { action: "accountSignIn", account };
  return { action: "accountAdd", family, way: "new", ...(name?.trim() ? { name: name.trim() } : {}) };
}
