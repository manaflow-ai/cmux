// Settings > Accounts' in-place sign-in (logins done right). Leo, 2026-11-22: "we likewise want gh
// auth or device stuff to be much more convienient ui/ux wise ... WE ABSOLUELY MUST ERR ON THE SIDE
// OF BEING NOT ANNOYING". One click on Add account or Sign in starts the daemon's sign-in through
// the host (`cmux.settings.accounts.run`, shared/signIn ACCOUNT_ACTIONS); the host opens the
// provider's page in the app's browser pane, the code goes on the clipboard and shows in the row,
// and the row turns into the signed-in account by itself. Drawn only when the host lists the
// accounts (`accounts.signInAccounts`); an older host keeps the terminal sign-in (Agents >
// Harnesses), and a host that answers a start without a sign-in gets the same terminal gesture.
// The controller is shared/signIn/useAccountSignIn.ts, the same one onboarding runs.
import { useMemo } from "react";
import { useSettingsState, useStore } from "../context";
import {
  ACCOUNT_ACTIONS,
  parseAccountRow,
  type AccountFamily,
  type AccountRunParams,
} from "../../shared/signIn/accountSignIn";
import { AccountSwitcher } from "../../shared/signIn/AccountSwitcher";
import { useAccountSignIn, type AccountSignInTransport } from "../../shared/signIn/useAccountSignIn";

export function AccountSignInSection() {
  const store = useStore();
  const listed = useSettingsState().accounts?.signInAccounts;
  const transport = useMemo<AccountSignInTransport>(
    () => ({
      run: (params: AccountRunParams) => store.runAccountSignIn(params),
      // A host that does not sign in in place: the terminal sign-in, as Agents > Harnesses runs it.
      fallback: (family: AccountFamily, account: string | null) => {
        if (family !== "github")
          void store.runHarnesses(
            account ? { action: "accountSignIn", account } : { action: "accountAdd", family, way: "new" },
          );
      },
    }),
    [store],
  );
  const signIn = useAccountSignIn(transport);

  if (!Array.isArray(listed)) return null;
  const accounts = listed.flatMap((raw) => parseAccountRow(raw) ?? []);
  return (
    <div className="accounts-sign-in" data-card="account-sign-in">
      <AccountSwitcher
        accounts={accounts}
        signIn={signIn.running}
        busy={signIn.busy}
        look="inline"
        onAdd={(family) => signIn.start(family, null)}
        onSignIn={(account) => signIn.start(account.family, account.id)}
        onUse={(account) => signIn.gesture(ACCOUNT_ACTIONS.switch, account)}
        onSignOut={(account) => signIn.gesture(ACCOUNT_ACTIONS.signOut, account)}
        onRemove={(account) => signIn.gesture(ACCOUNT_ACTIONS.remove, account)}
        card={signIn.card}
      />
    </div>
  );
}
