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
// usage read before a sign-out no longer belongs to anyone signed in. Remove runs on the click: it
// takes the account out of cmux's list, and its login folder (or its key) and the CLI's own sign-in
// stay where they are.
// Sign In and a new login's Add account use the in-place sign-in card (`signIn`, from the harness
// row, on a host that signs in in place; logins done right, Leo 2026-11-22: "this is simply logins,
// done righr."): the code and the provider's page instead of a terminal tab. Without it, or with a
// daemon that has no `_acpmux/account/sign_in`, the same gestures open the terminal tab as before.
import { type ComponentProps, createContext, memo, useContext, useId, useMemo, useState } from "react";
import { useStableHandlers } from "../../../agent-session/acpmux/stableHandlers";
import { useKeptItems } from "../keptItems";
import { PlanUsageCardBody } from "../../../agent-session/acpmux/PlanUsageCard";
import "../paneStrings";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import { Select } from "../editors/Select";
import { Switch } from "../editors/ToggleEditor";
import { planName } from "../harnesses";
import { SETTINGS_SENTENCES, type HarnessesRun, type ProviderAccount, type AccountCacheMiss } from "../ops";
import { userMessage } from "../../shared/userMessage";
import { t } from "../strings";
import type { SettingsSignIn } from "./useSettingsSignIn";

/** The families whose accounts Settings can add (a login folder per account, or an API key). */
const ADDABLE: Record<string, string> = { codex: "ChatGPT", claude: "Claude" };

const MISS_CAUSES = new Set(["expired", "compaction", "model", "effort"]);

/** The usage block's hover line: "Last prompt cache miss at 14:05: the cache expired" (feature map
 * `usage-per-account`, Leo 2026-11-23: "the last cache-miss cause"). Undefined with no miss known. */
export function cacheMissLine(miss: AccountCacheMiss | undefined, locale?: string): string | undefined {
  if (!miss || !Number.isFinite(miss.at) || miss.at <= 0) return undefined;
  const cause = MISS_CAUSES.has(miss.cause) ? miss.cause : "unknown";
  const when = new Date(miss.at).toLocaleString(locale, {
    hour: "numeric",
    minute: "2-digit",
    month: "short",
    day: "numeric",
  });
  return t(
    "settingsWindow.harnesses.accounts.lastCacheMiss",
    when,
    t(`settingsWindow.harnesses.accounts.cacheMiss.${cause}`),
  );
}

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

/** The folder a shadow home shares: `shadowOf` is a folder, or the id of the account whose folder it
 * shares (found in `byId`, built once per list). Null when it shares none. */
export function sharedFolder(account: ProviderAccount, byId: ReadonlyMap<string, ProviderAccount>): string | null {
  if (account.key || !account.shadowOf) return null;
  if (/^[~/]/.test(account.shadowOf)) return account.shadowOf;
  const other = byId.get(account.shadowOf);
  return other?.home ?? other?.defaultHome ?? account.defaultHome ?? account.shadowOf;
}

/** Where it signs in: its own folder (a shadow home says whose settings and chats it shares). */
export function accountFolderText(account: ProviderAccount, shared: string | null): string | null {
  if (account.key) return null;
  const folder = account.home ?? account.defaultHome ?? "";
  if (shared === null) return t("settingsWindow.harnesses.accounts.folder", folder);
  return `${folder} · ${t("settingsWindow.harnesses.accounts.shares", shared)}`;
}

/** A gesture in flight: every account's controls are disabled until it ends. The controls read it,
 * not the rows, so a gesture draws the controls again and leaves each row's own lines be. */
const AccountsBusy = createContext(false);

/** One account, a memo row: its own account (a read that left it alone keeps the object), the folder
 * it shares (not every account) and one stable `run`, so a gesture or a new read draws only the rows
 * it changed. */
const AccountRow = memo(function AccountRow({
  account,
  shared,
  run,
  signIn,
}: {
  account: ProviderAccount;
  shared: string | null;
  run(gesture: HarnessesRun): void;
  /** The row's in-place sign-in (the card under the harness row); none: the terminal tab. */
  signIn?: SettingsSignIn;
}) {
  const nameId = useId();
  const switchId = useId();
  const [renaming, setRenaming] = useState<string | null>(null);
  const folder = accountFolderText(account, shared);
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
              <BusyButton type="submit" className="button" disabled={!renaming.trim()}>
                {t("settingsWindow.density.save")}
              </BusyButton>
              <Button type="button" className="button" onClick={() => setRenaming(null)}>
                {t("settingsWindow.cancel")}
              </Button>
            </div>
          </form>
        )}
        <div className="accounts-buttons">
          {/* A disabled account is no default: new chats would keep running on an account turned off. */}
          {!account.default && account.enabled && (
            <BusyButton
              type="button"
              className="button"
              data-account-action="default"
              aria-describedby={nameId}
              onClick={() => run({ action: "accountDefault", account: account.id })}
            >
              {t("settingsWindow.harnesses.accounts.makeDefault")}
            </BusyButton>
          )}
          {renamable && renaming === null && (
            <BusyButton
              type="button"
              className="button"
              data-account-action="rename"
              aria-describedby={nameId}
              onClick={() => setRenaming(account.name)}
            >
              {t("settingsWindow.menus.rename")}
            </BusyButton>
          )}
          {!account.key && !account.signedIn && (
            <BusyButton
              type="button"
              className="button"
              data-account-action="signIn"
              aria-describedby={nameId}
              onClick={() => {
                const inTerminal = () => run({ action: "accountSignIn", account: account.id });
                if (signIn && cardFamily(account.family)) signIn.begin(account.family, account.id, inTerminal);
                else inTerminal();
              }}
            >
              {t("settingsWindow.harnesses.signIn")}
            </BusyButton>
          )}
          {!account.key && account.signedIn && (
            <BusyButton
              type="button"
              className="button"
              data-account-action="signOut"
              aria-describedby={nameId}
              onClick={() => run({ action: "accountSignOut", account: account.id })}
            >
              {t("settingsWindow.harnesses.accounts.signOut")}
            </BusyButton>
          )}
          {!account.builtin && (
            <BusyButton
              danger
              type="button"
              className="button danger"
              data-account-action="remove"
              aria-describedby={nameId}
              onClick={() => run({ action: "accountRemove", account: account.id })}
            >
              {t("settingsWindow.remove")}
            </BusyButton>
          )}
        </div>
        {account.usage && account.signedIn && (
          <div
            className="harness-account-usage"
            data-account-usage=""
            /* tooltip-allow: the last cache miss's cause is not on screen (Leo: "a hover line names the last miss cause") */
            title={cacheMissLine(account.usage.lastCacheMiss)}
            data-cache-miss={account.usage.lastCacheMiss?.cause}
          >
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
        <BusySwitch
          checked={account.enabled}
          labelId={`${switchId} ${nameId}`}
          onToggle={(on) => run({ action: "accountEnable", account: account.id, on })}
        />
      </div>
    </div>
  );
});

/** A row's button, disabled while a gesture is in flight (or for its own reason). */
function BusyButton({ disabled, ...props }: ComponentProps<typeof Button>) {
  return <Button {...props} disabled={useContext(AccountsBusy) || disabled} />;
}

/** A row's routing switch, disabled while a gesture is in flight. */
function BusySwitch(props: Omit<ComponentProps<typeof Switch>, "disabled">) {
  return <Switch {...props} disabled={useContext(AccountsBusy)} />;
}

/** Add account: a new login in a folder of its own (its sign-in shows in the card, else a terminal tab), or an API key
 * by its secret reference (`keychain:NAME`, `env:VAR`, `file:/path`; acpmux refuses a pasted key). */
function AddAccountForm({
  family,
  busy,
  run,
  onDone,
  signIn,
}: {
  family: string;
  busy: boolean;
  run(gesture: HarnessesRun): Promise<boolean>;
  onDone(): void;
  /** A new login signs in in the card (the daemon makes its folder and lists it once signed in). */
  signIn?: SettingsSignIn;
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
    if (way === "new" && signIn && cardFamily(family)) {
      signIn.begin(family, null, () => void run(gesture), name);
      onDone();
      return;
    }
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

/** Whether the in-place card signs `family`'s accounts in (Codex and Claude here). */
function cardFamily(family: string): family is "codex" | "claude" {
  return family === "codex" || family === "claude";
}

/** A provider's accounts, under its harness row; Codex and Claude also offer Add account. */
export function ProviderAccounts({
  family,
  accounts,
  signIn,
}: {
  family: string;
  accounts: ProviderAccount[];
  /** The harness row's in-place sign-in, on a host that has it. */
  signIn?: SettingsSignIn;
}) {
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
          setError(userMessage(failure, SETTINGS_SENTENCES));
          return false;
        },
      )
      .finally(() => setBusy(false));
  };
  const { onRun } = useStableHandlers({ onRun: (gesture: HarnessesRun) => void send(gesture) });
  // A read answers every account: one that did not change keeps its object, so its memo row skips it.
  const kept = useKeptItems(accounts, (account) => account.id);
  const byId = useMemo(() => new Map(kept.map((account) => [account.id, account])), [kept]);
  return (
    <div className="accounts-body harness-accounts" data-harness-accounts={family}>
      <div className="row-help">{t("settingsWindow.harnesses.accounts.help")}</div>
      <AccountsBusy.Provider value={busy}>
        {kept.map((account) => (
          <AccountRow
            key={account.id}
            account={account}
            shared={sharedFolder(account, byId)}
            run={onRun}
            {...(signIn ? { signIn } : {})}
          />
        ))}
      </AccountsBusy.Provider>
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
      {adding && (
        <AddAccountForm
          family={family}
          busy={busy}
          run={send}
          onDone={() => setAdding(false)}
          {...(signIn ? { signIn } : {})}
        />
      )}
      {error && (
        <div className="row-error" data-account-error="">
          {error}
        </div>
      )}
    </div>
  );
}
