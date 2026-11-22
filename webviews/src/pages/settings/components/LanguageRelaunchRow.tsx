// Settings > General > Language: the web UI and native text switch language live, but the menu bar
// and command names keep the language the app launched in. While the two differ, a row under the
// Language row offers to relaunch (the host op cmux.settings.language.relaunch).
import { Button } from "../../../ui/Button";
import { useSettingsState, useStore } from "../context";
import { rowsByKey } from "../schema";
import { valueOf } from "../store";
import { t } from "../strings";
import { navigatorLanguages } from "../../shared/appLanguage";
import { resolveLanguage } from "../../shared/i18n";
import { ActionRow } from "./ActionRow";

export const APP_LANGUAGE_KEY = "app.language";

/** The locales cmux ships: the Language row's choices but System. */
export function shippedLanguages(): string[] {
  return (rowsByKey.get(APP_LANGUAGE_KEY)?.choices ?? [])
    .map((choice) => choice.value)
    .filter((value) => value !== "system");
}

/** Whether the app's native menus (in the language it launched in: `launchLanguages`, the
 * app's preferred localizations WebKit fixed at launch) differ from the setting's language. */
export function menusNeedRelaunch(
  value: unknown,
  launchLanguages: readonly string[] = navigatorLanguages(),
  shipped: readonly string[] = shippedLanguages(),
): boolean {
  const launch = resolveLanguage(launchLanguages, shipped);
  const chosen = typeof value === "string" && value !== "system" ? resolveLanguage([value], shipped) : launch;
  return chosen !== launch;
}

/** The relaunch row with its Relaunch button, only while the menus' language differs. */
export function LanguageRelaunchRow() {
  const store = useStore();
  const state = useSettingsState();
  if (!menusNeedRelaunch(valueOf(state, APP_LANGUAGE_KEY))) return null;
  return (
    <ActionRow title={t("settingsPage.language.relaunch.title")} help="">
      <Button
        type="button"
        className="button"
        data-language-relaunch=""
        onClick={() => void store.runLanguageRelaunch()}
      >
        {t("settingsPage.language.relaunch.button")}
      </Button>
    </ActionRow>
  );
}
