// Chief > Credential Vault (cmux issue 26412): the keys and tokens agents use by name
// (`cmux vault exec --env NAME -- cmd`), from the host lists' `credential_vault` (the app's
// CredentialVaultBoard, live through cmux.settings.host.changed, so a `cmux vault set` shows at
// once). Each row: its name, its last use and who used it, an Agents switch (its scope), Replace and
// Delete. Never a value: Add and Replace open the app's secure entry sheet, which writes the
// Keychain itself, and Delete asks on a native sheet first.
import { useId, useState } from "react";
import { useSettingsState, useStore } from "../context";
import type { CredentialVaultConsumer, CredentialVaultSecret } from "../ops";
import type { CredentialVaultRun } from "../store";
import { locale, t } from "../strings";
import { Switch } from "../editors/ToggleEditor";

function when(ms: number): string | null {
  const date = new Date(ms);
  // The metadata cache accepts Int64 timestamps, whose range exceeds JavaScript's Date.
  if (!Number.isFinite(date.getTime())) return null;
  return new Intl.DateTimeFormat(locale(), { dateStyle: "medium", timeStyle: "short" }).format(date);
}

/** Keep a status on one short line; its full text remains available on hover and to assistive technology. */
function UseSummary({ secret }: { secret: CredentialVaultSecret }) {
  const full = useText(secret);
  const characters = [...new Intl.Segmenter(locale(), { granularity: "grapheme" }).segment(full)];
  const text =
    characters.length > 60
      ? `${characters
          .slice(0, 59)
          .map((part) => part.segment)
          .join("")}…`
      : full;
  return (
    <div className="row-help" title={text === full ? undefined : full} aria-label={full}>
      {text}
    </div>
  );
}

/** The scope with agents on or off; its other consumers stay (an agents-only secret stays
 * agents-only), and a scope left empty is the person's. */
export function withAgents(scope: CredentialVaultConsumer[], agents: boolean): CredentialVaultConsumer[] {
  const rest = scope.filter((consumer) => consumer !== "agents");
  if (agents) return [...rest, "agents"];
  return rest.length > 0 ? rest : ["user"];
}

/** Its last use and how often, or that nothing used it yet; then its note. */
function useText(secret: CredentialVaultSecret): string {
  const lastUsed = secret.last_used_ms === null ? null : when(secret.last_used_ms);
  const used =
    lastUsed === null
      ? t("settingsWindow.credentialVault.neverUsed")
      : t("settingsWindow.credentialVault.lastUsed", lastUsed, secret.last_used_by ?? "", String(secret.uses));
  return secret.note ? `${used} · ${secret.note}` : used;
}

function SecretRow({
  secret,
  busy,
  run,
}: {
  secret: CredentialVaultSecret;
  busy: boolean;
  run: (run: CredentialVaultRun) => void;
}) {
  const labelId = useId();
  const agents = secret.scope.includes("agents");
  return (
    <div className="row" tabIndex={-1} data-vault-secret={secret.name}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={labelId}>
            <code>{secret.name}</code>
          </div>
          <UseSummary secret={secret} />
        </div>
        <div className="row-control action-row-control">
          <span className="row-help" aria-hidden="true">
            {t("settingsWindow.credentialVault.agents")}
          </span>
          <Switch
            checked={agents}
            disabled={busy}
            labelId={labelId}
            onToggle={(next) => run({ op: "scope", name: secret.name, scope: withAgents(secret.scope, next) })}
          />
          <button
            type="button"
            className="button"
            data-vault="replace"
            disabled={busy}
            onClick={() => run({ op: "replace", name: secret.name })}
          >
            {t("settingsWindow.credentialVault.replace")}
          </button>
          <button
            type="button"
            className="button"
            data-vault="remove"
            disabled={busy}
            onClick={() => run({ op: "remove", name: secret.name })}
          >
            {t("settingsWindow.credentialVault.delete")}
          </button>
        </div>
      </div>
    </div>
  );
}

export function CredentialVaultCard() {
  const store = useStore();
  const vault = useSettingsState().host?.credential_vault;
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  if (!vault) return null;
  const run = async (gesture: CredentialVaultRun) => {
    setBusy(true);
    setRefusal(null);
    setRefusal(await store.runCredentialVault(gesture));
    setBusy(false);
  };
  const failure = refusal ?? vault.error;
  return (
    <section className="group" data-card="credential-vault">
      <h3 className="group-title">{t("settingsWindow.credentialVault.title")}</h3>
      <div className="rows">
        <div className="row" tabIndex={-1}>
          <div className="row-main">
            <div className="row-label">
              <div className="row-help">
                {vault.loaded && vault.secrets.length === 0
                  ? t("settingsWindow.credentialVault.empty")
                  : t("settingsWindow.credentialVault.help")}
              </div>
            </div>
            <div className="row-control action-row-control">
              <button
                type="button"
                className="button"
                data-vault="add"
                disabled={busy}
                onClick={() => void run({ op: "add" })}
              >
                {t("settingsWindow.credentialVault.add")}
              </button>
            </div>
          </div>
        </div>
        {vault.secrets.map((secret) => (
          <SecretRow key={secret.name} secret={secret} busy={busy} run={(gesture) => void run(gesture)} />
        ))}
      </div>
      {failure && (
        <output className="notice" data-vault-failed="">
          <span className="notice-text">{failure}</span>
        </output>
      )}
    </section>
  );
}
