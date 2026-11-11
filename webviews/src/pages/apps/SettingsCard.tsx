// The Settings card at the end of Discover (extensibility-DESIGN.md section 7, "Trim"): the store
// lists apps only, so a person looking for one of cmux's own switches (a background, a sidebar view,
// a New Tab widget) is sent to Settings, which lists every key with search. One button runs the host
// action `openSettings`; sidebar items are Edit Sidebar's job and the card says so.
import type { Strings } from "../shared/i18n";
import type { AppsStore } from "./store";

export function SettingsCard({ store, strings }: { store: AppsStore; strings: Strings }) {
  const { t } = strings;
  return (
    <section className="apps-settings-card" aria-labelledby="apps-settings-card-title">
      <span className="apps-settings-card-text">
        <strong id="apps-settings-card-title" className="apps-settings-card-title">
          {t("store.settings.title")}
        </strong>
        <span className="apps-settings-card-body">{t("store.settings.body")}</span>
      </span>
      <button type="button" className="apps-button" onClick={() => void store.openSettings()}>
        {t("store.settings.open")}
      </button>
    </section>
  );
}
