// Settings > Chief > Notices (Leo's list): the Chief's notices are the app's notifications, so this
// row opens Settings > Notifications rather than copying its controls (a setting has one home on
// the page).
import { useSettingsRouter } from "../context";
import { sectionHref } from "../router";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";

export function NoticesCard() {
  const router = useSettingsRouter();
  return (
    <section className="group" data-card="notices">
      <div className="rows">
        <ActionRow title={t("settingsWindow.chief.notices.title")} help={t("settingsWindow.chief.notices.help")}>
          <button type="button" className="button" onClick={() => router.history.push(sectionHref("notifications"))}>
            {t("settingsWindow.chief.notices.open")}
          </button>
        </ActionRow>
      </div>
    </section>
  );
}
