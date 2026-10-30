import React, { useState } from "react";
import { useT } from "./i18n";
import type { AcpmuxSecretAsk } from "./model";

/// An agent's ask for a secret (cx-ncc.42), among the chat's asks above the composer: what it asks
/// for and why, a private field, Provide and Decline. The value goes to acpmux only (`onAnswer`),
/// which keeps it in memory and gives the agent a one-use ref; the chat never shows it, and the
/// field empties as it is sent.
export function SecretCard({
  ask,
  agent,
  onAnswer,
}: {
  ask: AcpmuxSecretAsk;
  agent: string;
  /// `value` provides the secret; none declines.
  onAnswer(value?: string): void;
}) {
  const t = useT();
  const [value, setValue] = useState("");
  const provide = (event: React.FormEvent) => {
    event.preventDefault();
    if (!value) return;
    const sent = value;
    setValue("");
    onAnswer(sent);
  };
  return (
    <form className="acpmux-secret-card" aria-live="polite" onSubmit={provide}>
      <div className="acpmux-secret-card-text">
        <span className="acpmux-secret-card-ask">{t("secret.ask", { agent, name: ask.name })}</span>
        {ask.reason && <span className="acpmux-secret-card-reason">{ask.reason}</span>}
        <span className="acpmux-secret-card-private">{t("secret.private")}</span>
      </div>
      <div className="acpmux-secret-card-row">
        <input
          className="acpmux-secret-card-field"
          type="password"
          autoComplete="off"
          spellCheck={false}
          aria-label={t("secret.field", { name: ask.name })}
          placeholder={ask.name}
          value={value}
          onChange={(event) => setValue(event.target.value)}
        />
        <button type="submit" className="acpmux-secret-card-action" disabled={!value}>
          {t("secret.provide")}
        </button>
        <button type="button" className="acpmux-secret-card-action" onClick={() => onAnswer()}>
          {t("secret.decline")}
        </button>
      </div>
    </form>
  );
}
