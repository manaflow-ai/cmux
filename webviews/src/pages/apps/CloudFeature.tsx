// The featured Cloud banner at the top of Discover: what a cloud machine gives, and one button that
// opens the Cloud app's page (`app.open {app: "cmux/cloud"}`), whose storefront shows the plan's
// sizes and Get. The banner states no price or limit; the Cloud page reads those from the plan.
import type { Strings } from "../shared/i18n";
import type { AppsStore } from "./store";

/** The Cloud app (first-party-apps/cloud): its page holds the storefront. */
export const CLOUD_APP_ID = "cmux/cloud";

export function CloudFeature({ store, strings }: { store: AppsStore; strings: Strings }) {
  const { t } = strings;
  return (
    <section className="apps-cloud-feature" aria-labelledby="apps-cloud-feature-title">
      <span className="apps-cloud-feature-text">
        <span className="apps-cloud-feature-eyebrow">{t("store.cloud.eyebrow")}</span>
        <strong id="apps-cloud-feature-title" className="apps-cloud-feature-title">
          {t("store.cloud.title")}
        </strong>
        <span className="apps-cloud-feature-body">{t("store.cloud.body")}</span>
      </span>
      <svg className="apps-cloud-feature-art" viewBox="0 0 64 40" aria-hidden="true" focusable="false">
        <path d="M14 34 h36 a10 10 0 0 0 -1 -20 a14 14 0 0 0 -27 -2 a11 11 0 0 0 -8 22 z" />
        <circle cx="44" cy="26" r="2.5" />
      </svg>
      <button type="button" className="apps-button primary" onClick={() => void store.open(CLOUD_APP_ID)}>
        {t("store.cloud.open")}
      </button>
    </section>
  );
}
