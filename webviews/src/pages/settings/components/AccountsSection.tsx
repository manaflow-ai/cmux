// Settings > Accounts in the page (R82 commit 3). The host sends the screen as data with every text
// localized (`cmux.settings.accounts.state`, live through `cmux.settings.accounts.changed`) and
// runs each gesture (`cmux.settings.accounts.run`); the page only draws and forwards. A pasted key
// lives in this component's state until it is sent, never in the store, and is cleared after.
import { memo, useCallback, useEffect, useId, useMemo, useState } from "react";
import { useKeptItems } from "../keptItems";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { SignInBackend } from "../../../ui/SignInButton";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useSettingsSelector, useStore } from "../context";
import type { SettingsState } from "../store";
import { Select } from "../editors/Select";
import type { AccountsButton, AccountsCmux, AccountsRow, AccountsTeams } from "../ops";
import { t } from "../strings";
import { TeamsGroup } from "./AccountsTeams";
import { AccountSignInSection } from "./AccountSignInSection";
import { GitHubAccountsCard } from "./GitHubAccountsCard";
import { SlackAccountsCard } from "./SlackAccountsCard";
import { TeamAgentKeysCard } from "./TeamAgentKeysCard";
import { useSettingsSignIn } from "./useSettingsSignIn";

const accountsOf = (state: SettingsState) => state.accounts;

export function AccountsSection() {
  const store = useStore();
  const accounts = useSettingsSelector(accountsOf);
  // Like the Swift view's onAppear: detection runs again when the section mounts (a stable
  // callback ref runs once per mount).
  const mounted = useCallback(
    (node: HTMLDivElement | null) => {
      if (node) void store.runAccounts({ action: "refresh" });
    },
    [store],
  );
  // A login or logout runs in a terminal tab of the main window, so the app never goes inactive:
  // coming back to Settings (its window, or its tab) frees the rows it left busy (the host
  // ignores it when none are).
  useEffect(() => {
    const focused = () => {
      if (document.visibilityState === "visible") void store.runAccounts({ action: "focus" });
    };
    window.addEventListener("focus", focused);
    document.addEventListener("visibilitychange", focused);
    return () => {
      window.removeEventListener("focus", focused);
      document.removeEventListener("visibilitychange", focused);
    };
  }, [store]);
  return (
    <div className="accounts" data-card="accounts" ref={mounted}>
      {accounts && <AccountsBody />}
    </div>
  );
}

function AccountsBody() {
  const store = useStore();
  // Only the accounts part: another part of the page's state changing does not draw the section.
  const accounts = useSettingsSelector(accountsOf)!;
  const signIn = useSettingsSignIn();
  // The host sends the whole screen on every change: a provider's row that did not change keeps
  // its object, so its memo row skips the push.
  const rows = useKeptItems(
    useMemo(() => accounts.groups.flatMap((group) => group.rows), [accounts.groups]),
    (row) => row.provider,
  );
  const kept = useMemo(() => new Map(rows.map((row) => [row.provider, row])), [rows]);
  return (
    <>
      <section className="group">
        <div className="rows">
          <CmuxAccountRow cmux={accounts.cmux} />
        </div>
        <div className="accounts-header">
          <Button
            type="button"
            className="button"
            disabled={accounts.refreshing}
            onClick={() => void store.runAccounts({ action: "refresh" })}
          >
            {accounts.refresh}
          </Button>
        </div>
        {accounts.groups.length === 0 && (
          <output className="row-help block" data-accounts-empty="">
            {t("settingsPage.accounts.empty")}
          </output>
        )}
      </section>
      <GitHubAccountsCard signIn={signIn} />
      <AccountSignInSection signIn={signIn} />
      {accounts.teams && <ActiveTeam teams={accounts.teams} />}
      {accounts.teamList && <TeamsGroup list={accounts.teamList} />}
      <TeamAgentKeysCard />
      <SlackAccountsCard />
      {accounts.groups.map((group) => (
        <section className="group" key={group.id} data-accounts-group={group.id}>
          <h3 className="group-title">{group.title}</h3>
          <div className="rows">
            {group.rows.map((row) => (
              <AccountRow key={row.provider} row={kept.get(row.provider) ?? row} />
            ))}
          </div>
        </section>
      ))}
    </>
  );
}

// The team switcher: one settings row, "Active Team" and a pop-up menu of the teams (the settings
// Select, the same control as every menu setting), the active one checked. A choice runs
// selectTeam; the host's next state moves the check (and everything else that follows the team).
// With one team there is nothing to choose, so the menu shows it disabled.
function ActiveTeam({ teams }: { teams: AccountsTeams }) {
  const store = useStore();
  const labelId = useId();
  const active = teams.options.find((team) => team.active);
  return (
    <section className="group" data-accounts-teams="">
      <div className="rows">
        <div className="row accounts-teams">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title" id={labelId}>
                {teams.title}
              </div>
              <div className="row-help">{teams.note ?? teams.help}</div>
              {teams.error && (
                <div className="row-error" role="alert">
                  {teams.error}
                </div>
              )}
            </div>
            <div className="row-control">
              <Select
                value={active?.id ?? ""}
                disabled={teams.disabled || teams.options.length < 2}
                labelId={labelId}
                onChange={(team) => void store.runAccounts({ action: "selectTeam", team })}
              >
                {teams.options.map((team) => (
                  <option key={team.id} value={team.id}>
                    {team.name}
                  </option>
                ))}
              </Select>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

// cmux's own account: who is signed in and the gestures the host offers for that state (sign in,
// open the sign-in in the browser, cancel, switch account, sign out).
function CmuxAccountRow({ cmux }: { cmux: AccountsCmux }) {
  const store = useStore();
  return (
    <div className="row accounts-row" data-account="cmux">
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{cmux.title}</div>
          {cmux.detail && <div className="row-help">{cmux.detail}</div>}
        </div>
        <span
          className="accounts-status"
          data-status={cmux.statusKind}
          data-busy={cmux.busy || undefined}
          aria-busy={cmux.busy}
        >
          <span className="accounts-dot" aria-hidden="true" />
          {cmux.status}
        </span>
      </div>
      <div className="accounts-body">
        <div className="accounts-buttons">
          <Buttons buttons={cmux.buttons} onRun={(id) => void store.runAccounts({ action: id })} />
        </div>
        {cmux.signInBackend && <SignInBackend line={cmux.signInBackend} />}
        {cmux.note && <div className="row-help">{cmux.note}</div>}
        {cmux.error && (
          <div className="row-error" data-outcome="danger">
            {cmux.error}
          </div>
        )}
      </div>
    </div>
  );
}

function Buttons({ buttons, onRun }: { buttons: AccountsButton[]; onRun: (id: string) => void }) {
  return buttons.map((button) => (
    <Button
      danger={button.destructive}
      type="button"
      key={button.id}
      className={button.destructive ? "button danger" : "button"}
      disabled={button.disabled}
      data-account-button={button.id}
      onClick={() => onRun(button.id)}
    >
      {button.title}
    </Button>
  ));
}

/** One provider's account row, a memo row: a host push that left the provider alone keeps its row
 * object (useKeptItems), so it draws only the rows it changed. */
const AccountRow = memo(function AccountRow({ row }: { row: AccountsRow }) {
  const store = useStore();
  const run = (action: string) => store.runAccounts({ action, provider: row.provider });
  return (
    <div className="row accounts-row" data-account={row.provider}>
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          <AgentMark agent={row.provider} size={16} />
        </span>
        <div className="row-label">
          <div className="row-title">{row.name}</div>
          {row.detail && <div className="row-help">{row.detail}</div>}
        </div>
        <span className="accounts-status" data-status={row.statusKind}>
          <span className="accounts-dot" aria-hidden="true" />
          {row.status}
        </span>
      </div>
      <div className="accounts-body">
        {row.buttons.length > 0 && (
          <div className="accounts-buttons">
            <Buttons buttons={row.buttons} onRun={(id) => void run(id)} />
          </div>
        )}
        {row.note && <div className="row-help">{row.note}</div>}
        {row.outcome && (
          <div className={row.outcome.kind === "danger" ? "row-error" : "row-help"} data-outcome={row.outcome.kind}>
            {row.outcome.text}
          </div>
        )}
        {row.paste && <PasteForm row={row} paste={row.paste} />}
      </div>
    </div>
  );
});

function PasteForm({ row, paste }: { row: AccountsRow; paste: NonNullable<AccountsRow["paste"]> }) {
  const store = useStore();
  const [secret, setSecret] = useState("");
  const [error, setError] = useState<string | null>(null);
  const press = async (id: string) => {
    if (id === "saveKeychain") {
      const value = secret;
      setSecret("");
      const failure = await store.runAccounts({ action: id, provider: row.provider, secret: value });
      setError(failure);
      return;
    }
    if (id === "cancelPaste") setSecret("");
    setError(null);
    await store.runAccounts({ action: id, provider: row.provider });
  };
  const needsSecret = new Set(["saveKeychain"]);
  return (
    <div className="accounts-form" data-paste={row.provider}>
      <div className="row-title">{paste.title}</div>
      <div className="row-help">{paste.body}</div>
      <Input
        className="field"
        type="password"
        aria-label={paste.title}
        autoComplete="off"
        placeholder={paste.placeholder}
        value={secret}
        onChange={(event) => setSecret(event.target.value)}
      />
      {error && <div className="row-error">{error}</div>}
      <div className="accounts-buttons">
        <Buttons
          buttons={paste.buttons.map((button) =>
            needsSecret.has(button.id) && secret === "" ? { ...button, disabled: true } : button,
          )}
          onRun={(id) => void press(id)}
        />
      </div>
    </div>
  );
}
