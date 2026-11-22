// Settings > Accounts in the page (R82 commit 3). The host sends the screen as data with every text
// localized (`cmux.settings.accounts.state`, live through `cmux.settings.accounts.changed`) and
// runs each gesture (`cmux.settings.accounts.run`); the page only draws and forwards. A pasted key
// lives in this component's state until it is sent, never in the store, and is cleared after.
import { useCallback, useState } from "react";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useSettingsState, useStore } from "../context";
import type { AccountsButton, AccountsRow } from "../ops";

export function AccountsSection() {
  const store = useStore();
  const { accounts } = useSettingsState();
  // Like the Swift view's onAppear: detection runs again when the section mounts (a stable
  // callback ref runs once per mount).
  const mounted = useCallback(
    (node: HTMLDivElement | null) => {
      if (node) void store.runAccounts({ action: "refresh" });
    },
    [store],
  );
  return (
    <div className="accounts" data-card="accounts" ref={mounted}>
      {accounts && <AccountsBody />}
    </div>
  );
}

function AccountsBody() {
  const store = useStore();
  const accounts = useSettingsState().accounts!;
  return (
    <>
      <section className="group">
        <div className="accounts-header">
          {accounts.signIn && (
            <button
              type="button"
              className="button accounts-sign-in"
              onClick={() => void store.runAccounts({ action: "signIn" })}
            >
              {accounts.signIn}
            </button>
          )}
          <button
            type="button"
            className="button"
            disabled={accounts.refreshing}
            onClick={() => void store.runAccounts({ action: "refresh" })}
          >
            {accounts.refresh}
          </button>
        </div>
      </section>
      {accounts.groups.map((group) => (
        <section className="group" key={group.id} data-accounts-group={group.id}>
          <h3 className="group-title">{group.title}</h3>
          <div className="rows">
            {group.rows.map((row) => (
              <AccountRow key={row.provider} row={row} removeTitle={accounts.removeTitle} />
            ))}
          </div>
        </section>
      ))}
    </>
  );
}

function Buttons({ buttons, onRun }: { buttons: AccountsButton[]; onRun: (id: string) => void }) {
  return buttons.map((button) => (
    <button
      type="button"
      key={button.id}
      className={button.destructive ? "button danger" : "button"}
      disabled={button.disabled}
      data-account-button={button.id}
      onClick={() => onRun(button.id)}
    >
      {button.title}
    </button>
  ));
}

function AccountRow({ row, removeTitle }: { row: AccountsRow; removeTitle: string }) {
  const store = useStore();
  const run = (action: string, extra: { account?: string; secret?: string } = {}) =>
    store.runAccounts({ action, provider: row.provider, ...extra });
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
        {row.linked.map((account) => (
          <div className="accounts-linked" key={account.id} data-linked={account.id}>
            <span className="row-help">{account.label}</span>
            <span className={account.healthy ? "row-help" : "row-error"}>{account.state}</span>
            <button
              type="button"
              className="button danger"
              disabled={account.busy}
              onClick={() => void run("remove", { account: account.id })}
            >
              {removeTitle}
            </button>
          </div>
        ))}
        {row.note && <div className="row-help">{row.note}</div>}
        {row.outcome && (
          <div className={row.outcome.kind === "danger" ? "row-error" : "row-help"} data-outcome={row.outcome.kind}>
            {row.outcome.text}
          </div>
        )}
        {row.confirm && (
          <div className="accounts-form">
            <span>{row.confirm.text}</span>
            <div className="accounts-buttons">
              <button type="button" className="button" onClick={() => void run("confirm")}>
                {row.confirm.confirm}
              </button>
              <button type="button" className="button" onClick={() => void run("cancelConfirm")}>
                {row.confirm.cancel}
              </button>
            </div>
          </div>
        )}
        {row.paste && <PasteForm row={row} paste={row.paste} />}
      </div>
    </div>
  );
}

function PasteForm({ row, paste }: { row: AccountsRow; paste: NonNullable<AccountsRow["paste"]> }) {
  const store = useStore();
  const [secret, setSecret] = useState("");
  const [error, setError] = useState<string | null>(null);
  const press = async (id: string) => {
    if (id === "saveKeychain" || id === "sendCodeRouter") {
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
  const needsSecret = new Set(["saveKeychain", "sendCodeRouter"]);
  return (
    <div className="accounts-form" data-paste={row.provider}>
      <div className="row-title">{paste.title}</div>
      <div className="row-help">{paste.body}</div>
      <input
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
