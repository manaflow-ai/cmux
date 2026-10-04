// An installed app's grants: Run sandboxed, and one Allowed switch per scope with the app's reason.
// A revoke takes effect on the app's next call; a grant asks the host for a native confirmation.
import type { Strings } from "../shared/i18n";
import { dimmedWhenSandboxed, orderScopes, RiskLabel } from "./model";
import { Badge, Switch } from "./parts";
import type { AppsStore } from "./store";
import type { Grants } from "./types";

export function GrantsPanel({ grants, store, strings }: { grants: Grants; store: AppsStore; strings: Strings }) {
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
      {orderScopes(grants.scopes).map((row) => (
        <div key={row.scope} className={`apps-grant${grants.sandboxed && dimmedWhenSandboxed(row) ? " dimmed" : ""}`}>
          <div className="apps-grant-text">
            <span className="apps-grant-title">
              <code>{row.scope}</code>
              {row.risk !== "standard" && <Badge text={t(RiskLabel[row.risk])} />}
              {row.optional && <Badge text={t("store.detail.optional")} />}
            </span>
            <span className="apps-muted">{row.reason}</span>
          </div>
          <Switch
            on={row.granted}
            label={t("store.grants.granted")}
            onChange={(on) => void store.setGranted(grants.app, row.scope, on)}
          />
        </div>
      ))}
    </div>
  );
}
