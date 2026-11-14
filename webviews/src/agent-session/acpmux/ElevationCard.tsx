import React, { useState } from "react";
import { useT } from "./i18n";
import type { AcpmuxSecretAsk } from "./model";

/// An agent's ask to run one command as root (acpmux `hub/elevation.rs`, `request_elevation`),
/// among the chat's asks above the composer: who asks and on which machine, the exact argv sudo
/// runs, the agent's reason, a password field, Approve and Deny. The password goes to acpmux only
/// (`onAnswer`, the secret card's `secret_submit`), which hands it to sudo for this one command; the
/// chat never shows it, and the field empties as it is sent. Deny is final for the request.
export function ElevationCard({
  ask,
  agent,
  onAnswer,
}: {
  ask: AcpmuxSecretAsk;
  agent: string;
  /// `value` approves with the password; none denies. A rejection means the password did not go.
  onAnswer(value?: string): void | Promise<unknown>;
}) {
  const t = useT();
  const [value, setValue] = useState("");
  const [refused, setRefused] = useState(false);
  const [sending, setSending] = useState(false);
  const elevation = ask.elevation;
  if (!elevation) return null;
  const approve = (event: React.FormEvent) => {
    event.preventDefault();
    if (!value || sending) return;
    const sent = value;
    setValue("");
    setRefused(false);
    setSending(true);
    void Promise.resolve(onAnswer(sent)).then(
      () => setSending(false),
      () => {
        setSending(false);
        setRefused(true);
        setValue((current) => current || sent);
      },
    );
  };
  return (
    <form className="acpmux-secret-card acpmux-elevation-card" aria-live="polite" onSubmit={approve}>
      <div className="acpmux-secret-card-text">
        <span className="acpmux-secret-card-ask">{t("elevation.ask", { agent, host: elevation.host })}</span>
        <code className="acpmux-elevation-card-command">{commandLine(elevation.argv)}</code>
        {ask.reason && <span className="acpmux-secret-card-reason">{ask.reason}</span>}
        <span className="acpmux-secret-card-private">
          {t("elevation.private")}
          {elevation.timeoutSecs ? ` ${t("elevation.timeout", { seconds: elevation.timeoutSecs })}` : ""}
        </span>
      </div>
      <div className="acpmux-secret-card-row">
        <input
          className="acpmux-secret-card-field"
          type="password"
          autoComplete="off"
          spellCheck={false}
          aria-label={t("elevation.field")}
          placeholder={t("elevation.field")}
          value={value}
          aria-invalid={refused}
          onChange={(event) => {
            setRefused(false);
            setValue(event.target.value);
          }}
        />
        <button type="submit" className="acpmux-secret-card-action" disabled={!value || sending}>
          {t("elevation.approve")}
        </button>
        <button type="button" className="acpmux-secret-card-action" disabled={sending} onClick={() => onAnswer()}>
          {t("elevation.deny")}
        </button>
      </div>
    </form>
  );
}

/// The argv as the person reads it: `sudo` and each argument, quoted when it holds a space or a
/// shell character, so what runs is exactly what the card shows (sudo gets the argv, no shell).
export function commandLine(argv: readonly string[]): string {
  const quote = (arg: string) =>
    arg !== "" && /^[\w@%+=:,./-]+$/.test(arg) ? arg : `'${arg.replaceAll("'", `'\\''`)}'`;
  return ["sudo", ...argv.map(quote)].join(" ");
}
