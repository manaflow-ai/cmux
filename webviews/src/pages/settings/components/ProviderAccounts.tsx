// Agents > Harnesses: a provider's accounts under its row (acpmux `_acpmux/accounts`, Leo 2026-11-05:
// "we have code router, but we don't have the codex signed account, like auto routing permission").
// One row per account: the CLI's own login and each added one, with who it is signed in as and its
// plan (the address shows on this local page only), its login folder, and a switch that lets routing
// move chats onto it. Each row also offers what the model picker's Account menu does (Leo, 2026-11-05:
// "i meant can you do all of htem"): Make Default, Rename, Sign In or Sign Out, and Remove for an added
// one. Add account (Codex and Claude) signs in a new login in a folder of its own (for Codex a shadow
// home that shares settings and chats with the CLI's), or adds an API key by its secret reference.
// An account whose plan usage was read when Settings opened shows its 5-hour and weekly limits under
// it, in the composer ring's plan usage card (PlanUsageCardBody); a signed-out one shows none, since
// usage read before a sign-out no longer belongs to anyone signed in. Remove asks first, in the row
// (as a team's Delete does): it takes the account out of cmux's list, and its login folder and the
// CLI's own sign-in stay where they are.
import { useEffect, useId, useRef, useState, type KeyboardEvent } from "react";
import { PlanUsageCardBody } from "../../../agent-session/acpmux/PlanUsageCard";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import { Select } from "../editors/Select";
import { Switch } from "../editors/ToggleEditor";
import { planName } from "../harnesses";
import type { HarnessesRun, ProviderAccount } from "../ops";
import { t } from "../strings";

/** The families whose accounts Settings can add (a login folder per account, or an API key). */
const ADDABLE: Record<string, string> = { codex: "ChatGPT", claude: "Claude" };

/** "Authenticated as alex@example.com · ChatGPT Pro", or "Not signed in". */
export function accountAuthText(account: ProviderAccount): string {
  if (!account.signedIn) return t("settingsWindow.harnesses.notAuthenticated");
  const plan = account.key ? t("settingsWindow.harnesses.accounts.apiKey") : planName(account.family, account.plan);
  if (account.email) {
    return plan
      ? t("settingsWindow.harnesses.accounts.authenticatedAsPlan", account.email, plan)
      : t("settingsWindow.harnesses.accounts.authenticatedAs", account.email);
  }
  return plan ? t("settingsWindow.harnesses.authenticatedPlan", plan) : t("settingsWindow.harnesses.authenticated");
}

/** Where it signs in: its own folder (a shadow home says whose settings and chats it shares). */
export function accountFolderText(account: ProviderAccount, all: ProviderAccount[]): string | null {
  if (account.key) return null;
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
  const [renaming, setRenaming] = useState<string | null>(null);
  const [confirmingRemove, setConfirmingRemove] = useState(false);
  const cancelRemoveRef = useRef<HTMLButtonElement>(null);
  // The question takes focus when it opens (the Remove button it replaces is gone), so Escape closes it.
  useEffect(() => {
    if (confirmingRemove) cancelRemoveRef.current?.focus();
  }, [confirmingRemove]);
  const escapeRemove = (event: KeyboardEvent) => {
    if (event.key === "Escape") setConfirmingRemove(false);
  };
  const folder = accountFolderText(account, all);
  // acpmux keeps no file for the Claude Code login, so it has no name of its own to change.
  const renamable = account.id !== "claude-login";
  const rename = () => {
    const name = renaming?.trim();
    if (name && name !== account.name) run({ action: "accountRename", account: account.id, name });
    setRenaming(null);
  };
  return (
    <div className="harness-account" data-account={account.id}>
      <div className="harness-account-copy">
        <div className="harness-account-name" id={nameId}>
          {account.name}
          {account.builtin && <span className="accounts-badge">{t("settingsWindow.harnesses.accounts.cliLogin")}</span>}
          {account.default && (
            <span className="accounts-badge" data-account-default="">
              {t("settingsWindow.harnesses.accounts.default")}
            </span>
          )}
        </div>
        <div className="row-help" data-account-auth={account.signedIn ? "signedIn" : "signedOut"}>
          {accountAuthText(account)}
        </div>
        {folder && (
          <div className="row-help selectable" data-account-folder="">
            {folder}
          </div>
        )}
        {renaming !== null && (
          <form
            className="accounts-form"
            data-account-rename=""
            onSubmit={(event) => {
              event.preventDefault();
              rename();
            }}
          >
            <Input
              className="field"
              aria-labelledby={nameId}
              autoComplete="off"
              maxLength={128}
              value={renaming}
              onChange={(event) => setRenaming(event.target.value)}
            />
            <div className="accounts-buttons">
              <Button type="submit" className="button" disabled={busy || !renaming.trim()}>
                {t("settingsWindow.density.save")}
              </Button>
              <Button type="button" className="button" onClick={() => setRenaming(null)}>
                {t("settingsWindow.cancel")}
              </Button>
            </div>
          </form>
        )}
        <div className="accounts-buttons">
          {/* A disabled account is no default: new chats would keep running on an account turned off. */}
          {!account.default && account.enabled && (
            <Button
              type="button"
              className="button"
              data-account-action="default"
              aria-describedby={nameId}
              disabled={busy}
              onClick={() => run({ action: "accountDefault", account: account.id })}
            >
              {t("settingsWindow.harnesses.accounts.makeDefault")}
            </Button>
          )}
          {renamable && renaming === null && (
            <Button
              type="button"
              className="button"
              data-account-action="rename"
              aria-describedby={nameId}
              disabled={busy}
              onClick={() => setRenaming(account.name)}
            >
              {t("settingsWindow.menus.rename")}
            </Button>
          )}
          {!account.key && !account.signedIn && (
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
          {!account.key && account.signedIn && (
            <Button
              type="button"
              className="button"
              data-account-action="signOut"
              aria-describedby={nameId}
              disabled={busy}
              onClick={() => run({ action: "accountSignOut", account: account.id })}
            >
              {t("settingsWindow.harnesses.accounts.signOut")}
            </Button>
          )}
          {!account.builtin && !confirmingRemove && (
            <Button
              danger
              type="button"
              className="button danger"
              data-account-action="remove"
              aria-describedby={nameId}
              disabled={busy}
              onClick={() => setConfirmingRemove(true)}
            >
              {t("settingsWindow.remove")}
            </Button>
          )}
        </div>
        {!account.builtin && confirmingRemove && (
          <div className="accounts-form" data-account-remove-confirm="" role="alertdialog" aria-labelledby={nameId}>
            <span className="row-help">
              {t(
                account.key
                  ? "settingsWindow.harnesses.accounts.removeConfirmKey"
                  : "settingsWindow.harnesses.accounts.removeConfirm",
                account.name,
              )}
            </span>
            <div className="accounts-buttons">
              <Button
                danger
                type="button"
                className="button danger"
                data-account-action="confirmRemove"
                disabled={busy}
                onKeyDown={escapeRemove}
                onClick={() => {
                  setConfirmingRemove(false);
                  run({ action: "accountRemove", account: account.id });
                }}
              >
                {t("settingsWindow.remove")}
              </Button>
              <Button
                type="button"
                className="button"
                data-account-action="cancelRemove"
                ref={cancelRemoveRef}
                onKeyDown={escapeRemove}
                onClick={() => setConfirmingRemove(false)}
              >
                {t("settingsWindow.cancel")}
              </Button>
            </div>
          </div>
        )}
        {account.usage && account.signedIn && (
          <div className="harness-account-usage" data-account-usage="">
            {/* No family: the card's usage-page link opens through the agent pane's browser, which
                Settings does not have. */}
            <PlanUsageCardBody limits={account.usage} />
          </div>
        )}
      </div>
      <div className="row-control">
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

/** Add account: a new login in a folder of its own (its sign-in opens in a terminal tab), or an API key
 * by its secret reference (`keychain:NAME`, `env:VAR`, `file:/path`; acpmux refuses a pasted key). */
function AddAccountForm({
  family,
  busy,
  run,
  onDone,
}: {
  family: string;
  busy: boolean;
  run(gesture: HarnessesRun): Promise<boolean>;
  onDone(): void;
}) {
  const wayId = useId();
  const nameId = useId();
  const secretId = useId();
  const [way, setWay] = useState<"new" | "key">("new");
  const [name, setName] = useState("");
  const [secret, setSecret] = useState("");
  const brand = ADDABLE[family] ?? family;
  const ready = way === "new" || !!secret.trim();
  const submit = async () => {
    if (!ready) return;
    const gesture: HarnessesRun = { action: "accountAdd", family, way };
    if (name.trim()) gesture.name = name.trim();
    if (way === "key") gesture.secret = secret.trim();
    if (await run(gesture)) onDone();
  };
  return (
    <form
      className="accounts-form"
      data-account-add={family}
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <div className="row-title" id={wayId}>
        {t("settingsWindow.harnesses.accounts.add")}
      </div>
      <Select value={way} labelId={wayId} disabled={busy} onChange={(value) => setWay(value === "key" ? "key" : "new")}>
        <option value="new">{t("settingsWindow.harnesses.accounts.addWayNew", brand)}</option>
        <option value="key">{t("settingsWindow.harnesses.accounts.addWayKey")}</option>
      </Select>
      <label className="row-help" id={nameId}>
        {t("settingsWindow.harnesses.accounts.name")}
      </label>
      <Input
        className="field"
        aria-labelledby={nameId}
        autoComplete="off"
        maxLength={128}
        value={name}
        disabled={busy}
        onChange={(event) => setName(event.target.value)}
      />
      {way === "key" && (
        <>
          <label className="row-help" id={secretId}>
            {t("settingsWindow.harnesses.accounts.secret")}
          </label>
          <Input
            className="field"
            aria-labelledby={secretId}
            autoComplete="off"
            spellCheck={false}
            maxLength={4096}
            placeholder="keychain:NAME"
            value={secret}
            disabled={busy}
            onChange={(event) => setSecret(event.target.value)}
          />
          <div className="row-help">{t("settingsWindow.harnesses.accounts.secretHint")}</div>
        </>
      )}
      <div className="accounts-buttons">
        <Button type="submit" className="button" data-account-action="addConfirm" disabled={busy || !ready}>
          {t("settingsWindow.harnesses.accounts.add")}
        </Button>
        <Button type="button" className="button" onClick={onDone}>
          {t("settingsWindow.cancel")}
        </Button>
      </div>
    </form>
  );
}

/** A provider's accounts, under its harness row; Codex and Claude also offer Add account. */
export function ProviderAccounts({ family, accounts }: { family: string; accounts: ProviderAccount[] }) {
  const store = useStore();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  /** Runs a gesture; resolves whether the host took it. */
  const send = (gesture: HarnessesRun): Promise<boolean> => {
    setBusy(true);
    setError(null);
    return store
      .runHarnesses(gesture)
      .then(
        () => true,
        (failure: unknown) => {
          setError(failure instanceof Error ? failure.message : String(failure));
          return false;
        },
      )
      .finally(() => setBusy(false));
  };
  const run = (gesture: HarnessesRun) => void send(gesture);
  return (
    <div className="accounts-body harness-accounts" data-harness-accounts={family}>
      <div className="row-help">{t("settingsWindow.harnesses.accounts.help")}</div>
      {accounts.map((account) => (
        <AccountRow key={account.id} account={account} all={accounts} run={run} busy={busy} />
      ))}
      {family in ADDABLE && !adding && (
        <div className="accounts-buttons">
          <Button
            type="button"
            className="button"
            data-account-action="add"
            disabled={busy}
            onClick={() => setAdding(true)}
          >
            {t("settingsWindow.harnesses.accounts.add")}
          </Button>
        </div>
      )}
      {adding && <AddAccountForm family={family} busy={busy} run={send} onDone={() => setAdding(false)} />}
      {error && (
        <div className="row-error" data-account-error="">
          {error}
        </div>
      )}
    </div>
  );
}
