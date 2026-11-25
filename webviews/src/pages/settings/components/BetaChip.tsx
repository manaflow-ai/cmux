import { t } from "../strings";

/** The small Beta chip beside an experimental row's title or the Experimental sidebar entry
 * (`appearance.settingsBetaChips`, betaChips.ts). Its text joins the title's accessible name. */
export function BetaChip() {
  return (
    <span className="beta-chip" data-beta-chip="">
      {t("settingsPage.betaChip")}
    </span>
  );
}
