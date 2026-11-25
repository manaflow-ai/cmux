// Settings > Cloud > Cloud Environments: the account's Cloud environments, the Default first, each opening
// the same editor as the composer's Environment chip (pages/cloud/EnvironmentSheet.tsx): its setup script,
// variables, secrets and network. The Default is the setup new Cloud machines start from when a chat picks no
// other environment; every account has one, so it is never created here, only edited. Add Environment makes a
// named one and opens it in the editor. Every request goes through `cmux.settings.cloud_environment` to the
// platform's `/v1/cloud-environments`, as the composer's do (#47676: the card used to call CloudDO's
// `cloud.environment.*`, which no deployment serves). The list is read when the card mounts, on Refresh and
// when the editor closes; it does not poll.
import { useCallback, useEffect, useRef, useState } from "react";
import { EnvironmentSheet } from "../../cloud/EnvironmentSheet";
import type { CloudEnvironment, EnvironmentClient } from "../../cloud/environmentModel";
import { EnvironmentStore } from "../../cloud/environmentStore";
import type { Strings } from "../../shared/i18n";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import type { SettingsStore } from "../store";
import { locale, t } from "../strings";

/** The editor's client over the Settings page's host. */
export function settingsEnvironmentClient(store: SettingsStore): EnvironmentClient {
  return {
    list: () => store.cloudEnvironment("cloud.environment.list"),
    get: (id) => store.cloudEnvironment("cloud.environment.get", { id }),
    update: (id, patch) => store.cloudEnvironment("cloud.environment.update", { id, patch }),
    derive: (options) => store.cloudEnvironment("cloud.environment.derive", options),
    create: (environment) => store.cloudEnvironment("cloud.environment.create", { environment }),
  };
}

/** The editor's strings from the Settings table, which carries the Cloud page's `environment.` keys. */
const sheetStrings: Strings = {
  get language() {
    return locale();
  },
  t: (key) => t(key),
  format: (key, ...args) => t(key, ...args),
};

/** The Default first, then personal before team, then by name. */
export function orderedEnvironments(environments: CloudEnvironment[]): CloudEnvironment[] {
  const rank = (row: CloudEnvironment) => (row.is_default ? 0 : 2) + (row.scope === "personal" ? 0 : 1);
  return [...environments].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
}

type Listing =
  | { kind: "loading" }
  | { kind: "listed"; environments: CloudEnvironment[] }
  | { kind: "unavailable" }
  | { kind: "failed" };

const failureCode = (error: unknown) =>
  typeof error === "object" && error !== null && "code" in error ? String((error as { code: unknown }).code) : "";

export function CloudEnvironmentsCard() {
  const store = useStore();
  const [client] = useState(() => settingsEnvironmentClient(store));
  const [editor] = useState(() => new EnvironmentStore(client));
  const [listing, setListing] = useState<Listing>({ kind: "loading" });
  const [busy, setBusy] = useState(false);
  // Only the newest read lands: Refresh during the read the editor's close starts must not let the older reply
  // overwrite the newer list.
  const generation = useRef(0);
  const refresh = useCallback(async () => {
    const mine = ++generation.current;
    let next: Listing;
    try {
      next = { kind: "listed", environments: orderedEnvironments(await client.list()) };
    } catch (failure) {
      // Cloud is off by policy, or the person is signed out: the card explains instead of listing.
      next = failureCode(failure) === "cloud_disabled" ? { kind: "unavailable" } : { kind: "failed" };
    }
    if (mine === generation.current) setListing(next);
  }, [client]);
  // The list on mount, and again each time the editor closes (a save or a new environment shows at once).
  useEffect(() => {
    void refresh();
    let open = editor.getSnapshot().open;
    const unsubscribe = editor.subscribe(() => {
      const now = editor.getSnapshot().open;
      if (open && !now) void refresh();
      open = now;
    });
    return () => {
      unsubscribe();
    };
  }, [editor, refresh]);
  // A failed open (the read, or Add Environment's create) shows in the editor itself, with Retry.
  const run = async (gesture: () => Promise<void>) => {
    setBusy(true);
    try {
      await gesture();
    } finally {
      setBusy(false);
    }
  };
  return (
    <section className="group" data-card="cloudEnvironments">
      <h3 className="group-title">{t("settingsPage.cloudEnvironments.title")}</h3>
      <p className="row-help">{t("settingsPage.cloudEnvironments.intro")}</p>
      {listing.kind === "unavailable" ? (
        <div className="row" data-environments-unavailable="">
          <span className="row-help">{t("settingsPage.cloudEnvironments.unavailable")}</span>
        </div>
      ) : (
        <>
          <div className="rows">
            {listing.kind === "listed" && listing.environments.length === 0 && (
              <div className="row" data-environments-empty="">
                <span className="row-help">{t("settingsPage.cloudEnvironments.empty")}</span>
              </div>
            )}
            {listing.kind === "listed" &&
              listing.environments.map((row) => (
                <EnvironmentRow
                  key={row.id}
                  row={row}
                  busy={busy}
                  onEdit={() => void run(() => editor.open({ environmentId: row.id }))}
                />
              ))}
          </div>
          {listing.kind === "failed" && (
            <div className="row-error" data-environments-error="">
              {t("settingsPage.cloudEnvironments.loadFailed")}
            </div>
          )}
          <AddEnvironment busy={busy} onCreate={(name) => run(() => editor.open({ create: { name } }))} />
        </>
      )}
      <div className="host-footer">
        <Button
          type="button"
          className="button"
          data-environments="refresh"
          disabled={busy}
          onClick={() => void run(refresh)}
        >
          {t("settingsPage.cloudEnvironments.refresh")}
        </Button>
      </div>
      <EnvironmentSheet store={editor} strings={sheetStrings} />
    </section>
  );
}

function EnvironmentRow({ row, busy, onEdit }: { row: CloudEnvironment; busy: boolean; onEdit: () => void }) {
  const details = [
    t(
      row.scope === "team"
        ? "settingsPage.cloudEnvironments.scopeTeam"
        : "settingsPage.cloudEnvironments.scopePersonal",
    ),
    t(
      row.setup_script === null
        ? "settingsPage.cloudEnvironments.setupDerived"
        : "settingsPage.cloudEnvironments.setupCustom",
    ),
  ];
  return (
    <div className="row" data-environment={row.id} data-environment-default={row.is_default ? "" : undefined}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">
            {row.name}
            {row.is_default && (
              <span className="row-help" data-environment-badge="default">
                {" · "}
                {t("settingsPage.cloudEnvironments.default")}
              </span>
            )}
          </div>
          <div className="row-help" data-environment-details="">
            {details.join(" · ")}
          </div>
        </div>
        <div className="row-control">
          <Button type="button" className="button" data-environment-action="edit" disabled={busy} onClick={onEdit}>
            {t("settingsPage.cloudEnvironments.edit")}
          </Button>
        </div>
      </div>
    </div>
  );
}

/** Add Environment: a name, then the editor opens on the new environment. */
function AddEnvironment({ busy, onCreate }: { busy: boolean; onCreate: (name: string) => Promise<void> }) {
  const [name, setName] = useState<string | null>(null);
  if (name === null) {
    return (
      <div className="host-footer">
        <Button type="button" className="button" data-environments="add" disabled={busy} onClick={() => setName("")}>
          {t("settingsPage.cloudEnvironments.add")}
        </Button>
      </div>
    );
  }
  const create = async () => {
    const trimmed = name.trim();
    if (!trimmed) return;
    await onCreate(trimmed);
    setName(null);
  };
  return (
    <form
      className="host-form"
      data-environments-form="new"
      onSubmit={(event) => {
        event.preventDefault();
        void create();
      }}
    >
      <label className="host-field">
        <span className="row-help">{t("settingsPage.cloudEnvironments.name")}</span>
        <Input
          className="field"
          data-environment-field="name"
          aria-label={t("settingsPage.cloudEnvironments.name")}
          maxLength={80}
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
      </label>
      <div className="host-actions">
        <Button type="submit" className="button" data-environments="create" disabled={busy || !name.trim()}>
          {t("settingsPage.cloudEnvironments.create")}
        </Button>
        <Button
          type="button"
          className="button"
          data-environments="cancel"
          disabled={busy}
          onClick={() => setName(null)}
        >
          {t("settingsPage.cancel")}
        </Button>
      </div>
    </form>
  );
}
