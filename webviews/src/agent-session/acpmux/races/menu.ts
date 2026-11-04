import type { ChatMenuItem } from "../header/ChatHeaderTools";
import type { Translate } from "../i18n";

/** Keep the existing utility slot: a race must not push Archive below a short chat menu. */
export function raceToolsMenu(inspect: () => void, openRace: (() => void) | undefined, t: Translate): ChatMenuItem {
  const inspector = { key: "inspector", label: t("inspector.title"), onSelect: inspect };
  if (!openRace) return { ...inspector, icon: "code" };
  return {
    key: "tools",
    label: t("plus.tools"),
    icon: "code",
    children: [{ key: "race", label: t("race.open"), onSelect: openRace }, inspector],
  };
}
