// Agents > Harnesses: a provider's accounts under its row (acpmux `_acpmux/accounts`, Leo 2026-11-05:
// "we have code router, but we don't have the codex signed account, like auto routing permission").
// One row per account: the CLI's own login and each added one, with who it is signed in as and its
// plan (the address shows on this local page only), its login folder, and a switch that lets routing
// move chats onto it. Add account makes a shadow home (a login folder of its own that shares settings
// and chats with the CLI's) and starts its sign-in; nothing to type.
import { useId, useState } from "react";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import { planName } from "../harnesses";
import type { HarnessesRun, ProviderAccount } from "../ops";
import { t } from "../strings";

/** "Authenticated as alex@example.com · ChatGPT Pro", or "Not signed in". */
export function accountAuthText(account: ProviderAccount): string {
  if (!account.signedIn) return t("settingsWindow.harnesses.notAuthenticated");
  const plan = planName(account.family, account.plan);
  if (account.email) {
    return plan
      ? t("settingsWindow.harnesses.accounts.authenticatedAsPlan", account.email, plan)
      : t("settingsWindow.harnesses.accounts.authenticatedAs", account.email);
  }
  return plan ? t("settingsWindow.harnesses.authenticatedPlan", plan) : t("settingsWindow.harnesses.authenticated");
}

/** Where it signs in: its own folder (a shadow home says whose settings and chats it shares). */
export function accountFolderText(account: ProviderAccount, all: ProviderAccount[]): string {
  const folder = account.home ?? account.defaultHome ?? "";
  if (!account.shadowOf) return t("settingsWindow.harnesses.accounts.folder", folder);
  // `shadowOf` is a folder, or the id of the account whose folder it shares.
  const shared = /^[~/]/.test(account.shadowOf)
    ? account.shadowOf
    : (all.find((other) => other.id === account.shadowOf)?.home ??
      all.find((other) => other.id === account.shadowOf)?.defaultHome ??
      account.defaultHome ??
      account.shadowOf);
  return `${folder} · ${t("settingsWindow.harnesses.accounts.shares", shared)}`;
}

function AccountRow({
  account,
  all,
  run,
  busy,
}: {
  account: ProviderAccount;
  all: ProviderAccount[];
  run(gesture: HarnessesRun): void;
  busy: boolean;
}) {
  const nameId = useId();
  const switchId = useId();
  return (
    <div className="harness-account" data-account={account.id}>
      <div className="harness-account-copy">
        <div className="harness-account-name" id={nameId}>
          {account.name}
          {account.builtin && <span className="accounts-badge">{t("settingsWindow.harnesses.accounts.cliLogin")}</span>}
        </div>
        <div className="row-help" data-account-auth={account.signedIn ? "signedIn" : "signedOut"}>
          {accountAuthText(account)}
        </div>
        <div className="row-help selectable" data-account-folder="">
          {accountFolderText(account, all)}
        </div>
      </div>
      <div className="row-control">
        {!account.signedIn && (
          <Button
            type="button"
            className="button"
            data-account-action="signIn"
            aria-describedby={nameId}
            disabled={busy}
            onClick={() => run({ action: "accountSignIn", account: account.id })}
          >
            {t("settingsWindow.harnesses.signIn")}
          </Button>
        )}
        <span className="row-help" id={switchId}>
          {t("settingsWindow.harnesses.accounts.useForRouting")}
        </span>
        <Switch
          checked={account.enabled}
          disabled={busy}
          labelId={`${switchId} ${nameId}`}
          onToggle={(on) => run({ action: "accountEnable", account: account.id, on })}
        />
      </div>
    </div>
  );
}

/** A provider's accounts, under its harness row; `family` "codex" also offers Add account. */
export function ProviderAccounts({ family, accounts }: { family: string; accounts: ProviderAccount[] }) {
  const store = useStore();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const run = (gesture: HarnessesRun) => {
    setBusy(true);
    setError(null);
    void store
      .runHarnesses(gesture)
      .catch((failure: unknown) => setError(failure instanceof Error ? failure.message : String(failure)))
      .finally(() => setBusy(false));
  };
  return (
    <div className="accounts-body harness-accounts" data-harness-accounts={family}>
      <div className="row-help">{t("settingsWindow.harnesses.accounts.help")}</div>
      {accounts.map((account) => (
        <AccountRow key={account.id} account={account} all={accounts} run={run} busy={busy} />
      ))}
      {family === "codex" && (
        <div className="accounts-buttons">
          <Button
            type="button"
            className="button"
            data-account-action="add"
            disabled={busy}
            onClick={() => run({ action: "accountAdd", family })}
          >
            {t("settingsWindow.harnesses.accounts.add")}
          </Button>
        </div>
      )}
      {error && (
        <div className="row-error" data-account-error="">
          {error}
        </div>
      )}
    </div>
  );
}
