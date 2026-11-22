// An installed app's grants: Limit to what's allowed, and one Allowed switch per permission, in the
// same plain words as the listing (a heading per kind of access, the app's reason; never the scope
// id). A revoke takes effect on the app's next call; a grant asks the host for a native confirmation.
// An app with an `external` server also gets a Server row: once its server is allowed, the person
// makes a credential (behind the host's native sheet) for the program they start, shown here once.
import type { Strings } from "../shared/i18n";
import { dimmedWhenSandboxed, orderScopes, RiskLabel, scopeHeading } from "./model";
import { Badge, Switch } from "./parts";
import type { AppsStore } from "./store";
import { SERVER_SCOPE, type Grants, type ServerCredential } from "./types";

export function GrantsPanel({
  grants,
  store,
  strings,
  credential,
}: {
  grants: Grants;
  store: AppsStore;
  strings: Strings;
  /** The external server credential just made (the snapshot's `serverCredential`), shown once. */
  credential?: ServerCredential;
}) {
  const { t } = strings;
  return (
    <div className="apps-grants">
      <div className="apps-grant">
        <div className="apps-grant-text">
          <span className="apps-grant-title">{t("store.grants.sandboxed")}</span>
          <span className="apps-muted">{t("store.grants.sandboxedHelp")}</span>
        </div>
        <Switch
          on={grants.sandboxed}
          label={t("store.grants.sandboxed")}
          onChange={(on) => void store.setSandboxed(grants.app, on)}
        />
      </div>
      {orderScopes(grants.scopes).map((row) => {
        const heading = scopeHeading(row.scope, t);
        return (
          <div key={row.scope} className={`apps-grant${grants.sandboxed && dimmedWhenSandboxed(row) ? " dimmed" : ""}`}>
            <div className="apps-grant-text">
              {heading && <span className="apps-perm-heading">{heading}</span>}
              <span className="apps-grant-reason">
                <span className="selectable">{row.reason}</span>
                {row.optional && <Badge text={t("store.detail.optional")} />}
                {row.risk !== "standard" && <Badge text={t(RiskLabel[row.risk])} />}
              </span>
            </div>
            <Switch
              on={row.granted}
              label={t("store.grants.granted")}
              onChange={(on) => void store.setGranted(grants.app, row.scope, on)}
            />
          </div>
        );
      })}
      {grants.server === "external" && (
        <ServerCredentialRow
          grants={grants}
          credential={credential?.app === grants.app ? credential.credential : undefined}
          store={store}
          strings={strings}
        />
      )}
    </div>
  );
}

function ServerCredentialRow({
  grants,
  credential,
  store,
  strings,
}: {
  grants: Grants;
  credential?: string;
  store: AppsStore;
  strings: Strings;
}) {
  const { t } = strings;
  const allowed = grants.scopes.some((row) => row.scope === SERVER_SCOPE && row.granted);
  return (
    <div className="apps-grant apps-server-credential" data-server-credential={credential ? "shown" : "none"}>
      <div className="apps-grant-text">
        <span className="apps-grant-title">{t("store.server.title")}</span>
        <span className="apps-muted">{t(allowed ? "store.server.help" : "store.server.needsGrant")}</span>
        {credential && (
          <>
            <code className="apps-server-credential-value selectable">{credential}</code>
            <span className="apps-muted">{t("store.server.shownOnce")}</span>
          </>
        )}
      </div>
      {credential ? (
        <span className="apps-server-credential-actions">
          <button
            type="button"
            className="apps-button"
            onClick={() => void navigator.clipboard?.writeText(credential).catch(() => undefined)}
          >
            {t("store.server.copy")}
          </button>
          <button type="button" className="apps-button" onClick={() => store.dismissServerCredential()}>
            {t("store.server.done")}
          </button>
        </span>
      ) : (
        <button
          type="button"
          className="apps-button"
          disabled={!allowed}
          onClick={() => void store.makeServerCredential(grants.app)}
        >
          {t("store.server.make")}
        </button>
      )}
    </div>
  );
}
