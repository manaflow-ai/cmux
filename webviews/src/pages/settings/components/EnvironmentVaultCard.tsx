import { useCallback, useEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { Select } from "../../../ui/Select";
import { useStore } from "../context";
import { Icon } from "../icons";
import type { VaultDelivery, VaultEntry, VaultGrant, VaultRun, VaultState } from "../ops";
import { locale, t } from "../strings";
import { GroupHeader } from "./GroupHeader";
import { SettingsErrorRow } from "./SettingsErrorRow";

// Settings > Cloud > Environment (RFD 0222 (c)1, hq#37585): the person's vault through the daemon's
// `vault-env`. Variables (env delivery) agents read; Secrets (proxy delivery) agents see only as a
// placeholder the egress proxy fills in for the allowed hosts. A value is typed once and sent on Save;
// no answer carries it back, so it is never shown again. Rust checks everything; this card only
// asks, and refuses a key-shaped variable before sending so the person can keep it a secret.

/** The daemon's `vault.key_shaped_variable` rule: such a name is a secret, never a plain variable. */
export const KEY_SHAPED = /(^|_)(API_KEY|APIKEY|TOKEN|SECRET|SECRET_KEY|ACCESS_KEY|PRIVATE_KEY|PASSWORD|PASSWD)$/i;

/** The daemon's refusal codes the card explains; any other reads as the action's failure. */
const REFUSAL: Record<string, string> = {
  "vault.invalid_name": "settingsPage.vault.invalidName",
  "vault.invalid_hosts": "settingsPage.vault.invalidHosts",
  "vault.too_large": "settingsPage.vault.tooLarge",
  "vault.model_key_proxy_only": "settingsPage.vault.modelKeyProxyOnly",
};

/** Hosts as the person typed them: commas or spaces between, empties dropped. */
export const parseHosts = (text: string) =>
  text
    .split(/[\s,]+/)
    .map((host) => host.trim().toLowerCase())
    .filter(Boolean);

const when = (ms: number) => new Date(ms).toLocaleString(locale(), { dateStyle: "medium", timeStyle: "short" });

type Failure = { message: string; keyShaped?: string } | null;

export function EnvironmentVaultCard() {
  const store = useStore();
  const [state, setState] = useState<VaultState | null>(null);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<Failure>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const inFlight = useRef(false);
  const refresh = useCallback(async () => {
    const next = await store.vault();
    setState(next ?? { available: false, unsupported: true, entries: [], grants: [] });
  }, [store]);
  useEffect(() => {
    void refresh();
  }, [refresh]);
  /** One write, then a fresh read; true when the daemon took it. */
  const run = useCallback(
    async (gesture: VaultRun): Promise<boolean> => {
      if (inFlight.current) return false;
      inFlight.current = true;
      setBusy(true);
      setFailure(null);
      setNotice(null);
      try {
        const reply = await store.runVault(gesture);
        if (reply.error !== undefined) {
          setFailure(
            reply.code === "vault.key_shaped_variable"
              ? { message: t("settingsPage.vault.keyShaped", gesture.params.name), keyShaped: gesture.params.name }
              : {
                  message: t(
                    REFUSAL[reply.code ?? ""] ??
                      (gesture.action === "rm" ? "settingsPage.vault.deleteFailed" : "settingsPage.vault.saveFailed"),
                  ),
                },
          );
          return false;
        }
        if (reply.result?.warning) setNotice(t("settingsPage.vault.noHostsWarning"));
        await refresh();
        return true;
      } finally {
        inFlight.current = false;
        setBusy(false);
      }
    },
    [store, refresh],
  );
  // No `vault-env-v1` on this daemon: the card is not drawn at all.
  if (state?.unsupported) return null;
  const loading = state === null;
  const available = state?.available === true;
  const readFailed = available && state.error !== undefined;
  const refreshLabel = t("settingsPage.vault.refresh");
  return (
    <section className="group" data-card="environmentVault" aria-busy={busy || loading}>
      <GroupHeader title={t("settingsPage.vault.title")} help={t("settingsPage.vault.help")}>
        {available && (
          <Button
            icon
            variant="ghost"
            data-vault="refresh"
            disabled={busy}
            onClick={() => void refresh()}
            aria-label={refreshLabel}
            title={refreshLabel}
          >
            <Icon name="reset" />
          </Button>
        )}
      </GroupHeader>
      <div className="rows models-rows">
        {loading && <output className="row row-help">{t("settingsPage.vault.loading")}</output>}
        {state && !available && (
          <div className="row" data-vault-unavailable="">
            <span className="row-help">{t("settingsPage.vault.unavailable")}</span>
          </div>
        )}
        {readFailed && (
          <SettingsErrorRow
            message={t("settingsPage.vault.loadFailed")}
            retry={busy ? undefined : () => void refresh()}
          />
        )}
        {notice && (
          <output className="row row-help" data-vault-notice="">
            {notice}
          </output>
        )}
        {available && !readFailed && (
          <VaultLists
            entries={state.entries}
            grants={state.grants}
            grantsFailed={state.grantsCode !== undefined}
            busy={busy}
            failure={failure}
            clearFailure={() => setFailure(null)}
            run={run}
            refuse={(name) => setFailure({ message: t("settingsPage.vault.keyShaped", name), keyShaped: name })}
          />
        )}
      </div>
    </section>
  );
}

/** The three lists; split out so the gallery draws them from a fixed state. */
export function VaultLists({
  entries,
  grants,
  grantsFailed = false,
  busy,
  failure,
  clearFailure,
  run,
  refuse,
}: {
  entries: VaultEntry[];
  grants: VaultGrant[];
  grantsFailed?: boolean;
  busy: boolean;
  failure: Failure;
  clearFailure: () => void;
  run: (gesture: VaultRun) => Promise<boolean>;
  refuse: (name: string) => void;
}) {
  // Which form is open: an add (by delivery) or a policy edit (by name). One at a time.
  const [adding, setAdding] = useState<VaultDelivery | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  // A refused variable's name and value move into the Secret form as they were: nothing is retyped.
  const [carried, setCarried] = useState<{ name: string; value: string } | null>(null);
  const [lastDraft, setLastDraft] = useState<{ name: string; value: string } | null>(null);
  const open = (delivery: VaultDelivery) => {
    clearFailure();
    setEditing(null);
    setCarried(null);
    setLastDraft(null);
    setAdding(delivery);
  };
  const save = async (draft: { name: string; value: string; delivery: VaultDelivery; hosts: string[] }) => {
    const name = draft.name.trim();
    setLastDraft({ name, value: draft.value });
    if (draft.delivery === "env" && KEY_SHAPED.test(name)) return refuse(name);
    const params = {
      name,
      value: draft.value,
      delivery: draft.delivery,
      ...(draft.delivery === "proxy" ? { allowedHosts: draft.hosts } : {}),
    };
    if (await run({ action: "set", params })) {
      setAdding(null);
      setCarried(null);
      setLastDraft(null);
    }
  };
  const errorRow = failure && (
    <div className="row settings-error-row" data-vault-failure={failure.keyShaped ? "keyShaped" : ""}>
      <span className="row-error" role="alert">
        <Icon name="warning" />
        {failure.message}
      </span>
      {failure.keyShaped && (
        <span className="row-control">
          <Button
            type="button"
            data-vault="useSecret"
            disabled={busy}
            onClick={() => {
              const moved = lastDraft?.name === failure.keyShaped ? lastDraft : { name: failure.keyShaped!, value: "" };
              setLastDraft(null);
              clearFailure();
              setEditing(null);
              setCarried(moved);
              setAdding("proxy");
            }}
          >
            {t("settingsPage.vault.useSecret")}
          </Button>
        </span>
      )}
    </div>
  );
  const list = (delivery: VaultDelivery) => {
    const rows = entries.filter((entry) => entry.delivery === delivery);
    const env = delivery === "env";
    return (
      <div className="vault-list" data-vault-list={delivery}>
        <div className="row">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{t(env ? "settingsPage.vault.variables" : "settingsPage.vault.secrets")}</div>
              <div className="row-help">
                {t(env ? "settingsPage.vault.variablesHelp" : "settingsPage.vault.secretsHelp")}
              </div>
            </div>
            <span className="row-control">
              <Button
                variant="ghost"
                data-vault={env ? "addVariable" : "addSecret"}
                disabled={busy || adding === delivery}
                onClick={() => open(delivery)}
              >
                {t(env ? "settingsPage.vault.addVariable" : "settingsPage.vault.addSecret")}
              </Button>
            </span>
          </div>
        </div>
        {rows.length === 0 && adding !== delivery && (
          <div className="row" data-vault-empty={delivery}>
            <span className="row-help">
              {t(env ? "settingsPage.vault.noVariables" : "settingsPage.vault.noSecrets")}
            </span>
          </div>
        )}
        {rows.map((entry) => (
          <div className="row environment-row" key={entry.name} data-vault-entry={entry.name}>
            <div className="row-main">
              <div className="row-label">
                <div className="row-title">
                  <code>{entry.name}</code>
                </div>
                <div className="row-help">
                  {t("settingsPage.vault.details", entry.revision, when(entry.updatedAt))}
                  {!env &&
                    " · " +
                      (entry.allowedHosts.length > 0
                        ? t("settingsPage.vault.hostsList", entry.allowedHosts.join(", "))
                        : t("settingsPage.vault.noHosts"))}
                </div>
              </div>
              <span className="row-control">
                <Button
                  type="button"
                  data-vault-action="edit"
                  disabled={busy || editing === entry.name}
                  onClick={() => {
                    clearFailure();
                    setAdding(null);
                    setCarried(null);
                    setLastDraft(null);
                    setEditing(entry.name);
                  }}
                >
                  {t("settingsPage.vault.edit")}
                </Button>
                <Button
                  type="button"
                  data-vault-action="delete"
                  disabled={busy}
                  onClick={() => void run({ action: "rm", params: { name: entry.name } })}
                >
                  {t("settingsPage.vault.delete")}
                </Button>
              </span>
            </div>
            {editing === entry.name && (
              <PolicyForm
                entry={entry}
                busy={busy}
                onSave={async (delivery, hosts) => {
                  if (delivery === "env" && KEY_SHAPED.test(entry.name)) return refuse(entry.name);
                  const params = {
                    name: entry.name,
                    delivery,
                    ...(delivery === "proxy" ? { allowedHosts: hosts } : {}),
                  };
                  if (await run({ action: "policy", params })) setEditing(null);
                }}
                onCancel={() => setEditing(null)}
              />
            )}
          </div>
        ))}
        {adding === delivery && (
          <div className="row">
            <EntryForm
              key={`${delivery}:${carried?.name ?? ""}`}
              delivery={delivery}
              initial={carried}
              busy={busy}
              onSave={save}
              onCancel={() => {
                setAdding(null);
                setCarried(null);
                setLastDraft(null);
                clearFailure();
              }}
            />
          </div>
        )}
      </div>
    );
  };
  return (
    <>
      {errorRow}
      {list("env")}
      {list("proxy")}
      <div className="vault-list" data-vault-list="grants">
        <div className="row">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{t("settingsPage.vault.grants")}</div>
              <div className="row-help">{t("settingsPage.vault.grantsHelp")}</div>
            </div>
          </div>
        </div>
        {grantsFailed && (
          <div className="row" data-vault-failure="grants">
            <span className="row-error" role="alert">
              <Icon name="warning" />
              {t("settingsPage.vault.loadFailed")}
            </span>
          </div>
        )}
        {grants.length === 0 && !grantsFailed && (
          <div className="row" data-vault-empty="grants">
            <span className="row-help">{t("settingsPage.vault.noGrants")}</span>
          </div>
        )}
        {grants.map((grant) => (
          <div className="row" key={`${grant.kind}:${grant.id}`} data-vault-grant={grant.id}>
            <div className="row-main">
              <div className="row-label">
                <div className="row-title">
                  {t(grant.kind === "cloud" ? "settingsPage.vault.grantCloud" : "settingsPage.vault.grantJoined")}{" "}
                  <code>{grant.id}</code>
                </div>
                <div className="row-help">
                  {(grant.entries ? grant.entries.join(", ") : t("settingsPage.vault.grantAll")) +
                    " · " +
                    (grant.expiresAt === 0
                      ? t("settingsPage.vault.grantRevoked")
                      : t("settingsPage.vault.grantUntil", when(grant.expiresAt)))}
                </div>
              </div>
            </div>
          </div>
        ))}
      </div>
    </>
  );
}

/** Add: a name, the value once (a password field, cleared when the form closes) and, for a secret, its hosts. */
export function EntryForm({
  delivery,
  initial,
  busy,
  onSave,
  onCancel,
}: {
  delivery: VaultDelivery;
  initial?: { name: string; value: string } | null;
  busy: boolean;
  onSave: (draft: { name: string; value: string; delivery: VaultDelivery; hosts: string[] }) => void | Promise<void>;
  onCancel: () => void;
}) {
  const [name, setName] = useState(initial?.name ?? "");
  const [value, setValue] = useState(initial?.value ?? "");
  const [hosts, setHosts] = useState("");
  const secret = delivery === "proxy";
  return (
    <div className="host-form environment-form" data-vault-form={delivery}>
      <label className="host-field">
        <span>{t("settingsPage.vault.name")}</span>
        <Input
          className="field"
          data-vault-field="name"
          value={name}
          spellCheck={false}
          autoComplete="off"
          onChange={(event) => setName(event.currentTarget.value)}
        />
      </label>
      <label className="host-field">
        <span>{t("settingsPage.vault.value")}</span>
        <Input
          className="field"
          data-vault-field="value"
          type="password"
          value={value}
          autoComplete="new-password"
          onChange={(event) => setValue(event.currentTarget.value)}
        />
        <span className="row-help">{t("settingsPage.vault.valueOnce")}</span>
      </label>
      {secret && (
        <label className="host-field">
          <span>{t("settingsPage.vault.hosts")}</span>
          <Input
            className="field"
            data-vault-field="hosts"
            value={hosts}
            spellCheck={false}
            placeholder="api.example.com, *.example.com"
            onChange={(event) => setHosts(event.currentTarget.value)}
          />
          <span className="row-help">{t("settingsPage.vault.hostsHelp")}</span>
        </label>
      )}
      <div className="host-actions">
        <Button
          type="button"
          data-vault="save"
          disabled={busy || !name.trim() || !value}
          onClick={() => void onSave({ name, value, delivery, hosts: parseHosts(hosts) })}
        >
          {t("settingsPage.vault.save")}
        </Button>
        <Button type="button" variant="ghost" data-vault="cancel" disabled={busy} onClick={onCancel}>
          {t("settingsPage.vault.cancel")}
        </Button>
      </div>
    </div>
  );
}

/** Edit: the delivery and the hosts only; the value stays as saved (a new value is a new Add). */
export function PolicyForm({
  entry,
  busy,
  onSave,
  onCancel,
}: {
  entry: VaultEntry;
  busy: boolean;
  onSave: (delivery: VaultDelivery, hosts: string[]) => void | Promise<void>;
  onCancel: () => void;
}) {
  const [delivery, setDelivery] = useState<VaultDelivery>(entry.delivery);
  const [hosts, setHosts] = useState(entry.allowedHosts.join(", "));
  return (
    <div className="host-form environment-form" data-vault-policy={entry.name}>
      <label className="host-field">
        <span>{t("settingsPage.vault.kind")}</span>
        <Select
          label={t("settingsPage.vault.kind")}
          value={delivery}
          closeOnPick
          options={[
            { value: "proxy", label: t("settingsPage.vault.asSecret") },
            { value: "env", label: t("settingsPage.vault.asVariable") },
          ]}
          onChange={(next: string) => setDelivery(next as VaultDelivery)}
        />
      </label>
      {delivery === "proxy" && (
        <label className="host-field">
          <span>{t("settingsPage.vault.hosts")}</span>
          <Input
            className="field"
            data-vault-field="hosts"
            value={hosts}
            spellCheck={false}
            onChange={(event) => setHosts(event.currentTarget.value)}
          />
          <span className="row-help">{t("settingsPage.vault.hostsHelp")}</span>
        </label>
      )}
      <div className="host-actions">
        <Button
          type="button"
          data-vault="save"
          disabled={busy}
          onClick={() => void onSave(delivery, parseHosts(hosts))}
        >
          {t("settingsPage.vault.save")}
        </Button>
        <Button type="button" variant="ghost" data-vault="cancel" disabled={busy} onClick={onCancel}>
          {t("settingsPage.vault.cancel")}
        </Button>
      </div>
    </div>
  );
}
