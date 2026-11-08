// Settings > Accounts > Team agent keys: the active team's shared Claude and Codex keys. The host
// sends every text localized and never a key (only whether one is set, its kind, its last four
// characters for admins, and when); admins add, replace and remove, members read the status. A pasted
// key lives only in the open form's state until it is sent, then is cleared.
import { useId, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { SignInButton } from "../../../ui/SignInButton";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useSettingsState, useStore } from "../context";
import { Select } from "../editors/Select";
import type { TeamAgentKeyRow, TeamAgentKeysState } from "../ops";

export function TeamAgentKeysCard() {
  const keys = useSettingsState().accounts?.agentKeys;
  const store = useStore();
  if (!keys) return null;
  return (
    <section className="group" data-card="team-agent-keys" aria-busy={keys.busy}>
      <h3 className="group-title">{keys.title}</h3>
      <div className="rows">
        <div className="row accounts-row">
          <div className="row-label">
            <p className="row-help">{keys.detail}</p>
            {keys.note && (
              <p className="row-help" data-agent-keys-note="">
                {keys.note}
              </p>
            )}
            {keys.error && (
              <p className="row-error" role="alert">
                {keys.error}
              </p>
            )}
          </div>
          <div className="accounts-body">
            <div className="accounts-buttons">
              {keys.signIn ? (
                <SignInButton label={keys.signIn} onSignIn={() => void store.runAccounts({ action: "signIn" })} />
              ) : (
                keys.agents.length > 0 && (
                  <Button
                    className="button"
                    disabled={keys.busy}
                    onClick={() => void store.runAccounts({ action: "agentKeyRefresh" })}
                  >
                    {keys.refresh}
                  </Button>
                )
              )}
            </div>
          </div>
        </div>
        {keys.agents.map((row) => (
          <AgentKeyRow key={row.agent} row={row} keys={keys} />
        ))}
      </div>
    </section>
  );
}

function AgentKeyRow({ row, keys }: { row: TeamAgentKeyRow; keys: TeamAgentKeysState }) {
  const store = useStore();
  const [mode, setMode] = useState<"idle" | "edit" | "confirm">("idle");
  const labels = keys.labels;
  return (
    <div className="row accounts-row" data-agent-key={row.agent}>
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          <AgentMark agent={row.agent} size={16} />
        </span>
        <div className="row-label">
          <div className="row-title">{row.name}</div>
          {row.detail && <div className="row-help">{row.detail}</div>}
        </div>
        <span className="accounts-status" data-status={row.set ? "success" : "quiet"}>
          <span className="accounts-dot" aria-hidden="true" />
          {row.status}
        </span>
      </div>
      <div className="accounts-body">
        {keys.canManage && mode === "idle" && (
          <div className="accounts-buttons">
            <Button
              className="button"
              data-agent-key-action="edit"
              disabled={keys.busy}
              onClick={() => setMode("edit")}
            >
              {row.set ? labels.replace : labels.add}
            </Button>
            {row.set && (
              <Button
                danger
                className="button danger"
                data-agent-key-action="remove"
                disabled={keys.busy}
                onClick={() => setMode("confirm")}
              >
                {labels.remove}
              </Button>
            )}
          </div>
        )}
        {keys.canManage && mode === "confirm" && (
          <div className="accounts-form" data-agent-key-confirm="">
            <output className="row-help">{labels.confirmRemove}</output>
            <div className="accounts-buttons">
              <Button
                danger
                className="button danger"
                data-agent-key-action="confirm-remove"
                disabled={keys.busy}
                onClick={() => {
                  setMode("idle");
                  void store.runAccounts({ action: "agentKeyRemove", provider: row.agent });
                }}
              >
                {labels.remove}
              </Button>
              <Button className="button" onClick={() => setMode("idle")}>
                {labels.cancel}
              </Button>
            </div>
          </div>
        )}
        {keys.canManage && mode === "edit" && <KeyForm row={row} keys={keys} onDone={() => setMode("idle")} />}
        {row.notice && <output className="row-help">{row.notice}</output>}
        {row.error && (
          <div className="row-error" role="alert" data-outcome="danger">
            {row.error}
          </div>
        )}
      </div>
    </div>
  );
}

function KeyForm({ row, keys, onDone }: { row: TeamAgentKeyRow; keys: TeamAgentKeysState; onDone: () => void }) {
  const store = useStore();
  const kindLabel = useId();
  const [kind, setKind] = useState<string>(keys.kinds[0]?.id ?? "api_key");
  const [secret, setSecret] = useState("");
  const labels = keys.labels;
  const send = () => {
    const value = secret;
    setSecret("");
    onDone();
    void store.runAccounts({ action: "agentKeySave", provider: row.agent, name: kind, secret: value });
  };
  return (
    <form
      className="accounts-form"
      data-agent-key-form={row.agent}
      onSubmit={(event) => {
        event.preventDefault();
        // Enter in the field submits even while a change is in flight; the app would drop it, so keep the key here.
        if (!keys.busy && secret.trim() !== "") send();
      }}
    >
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={kindLabel}>
            {labels.kind}
          </div>
        </div>
        <div className="row-control">
          <Select value={kind} disabled={keys.busy} labelId={kindLabel} onChange={setKind}>
            {keys.kinds.map((option) => (
              <option key={option.id} value={option.id}>
                {option.title}
              </option>
            ))}
          </Select>
        </div>
      </div>
      <Input
        className="field"
        type="password"
        aria-label={labels.secret}
        autoComplete="off"
        spellCheck={false}
        placeholder={labels.placeholder}
        value={secret}
        onChange={(event) => setSecret(event.target.value)}
      />
      <div className="accounts-buttons">
        <Button
          type="button"
          className="button"
          data-agent-key-action="save"
          disabled={keys.busy || secret.trim() === ""}
          onClick={send}
        >
          {labels.save}
        </Button>
        <Button
          type="button"
          className="button"
          onClick={() => {
            setSecret("");
            onDone();
          }}
        >
          {labels.cancel}
        </Button>
      </div>
    </form>
  );
}
