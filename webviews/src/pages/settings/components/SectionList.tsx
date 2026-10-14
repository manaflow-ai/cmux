import { useSettingsState } from "../context";
import { categoryRows, shownCategories } from "../categories";
import { settingsFileName } from "../format";
import { Icon } from "../icons";
import type { SettingsState } from "../store";
import { managedOf } from "../store";
import { t, text } from "../strings";
import { harnessesNeedAttention } from "../harnesses";

function badge(state: SettingsState, category: string): "warning" | "lock" | "update" | null {
  const keys = categoryRows(category).map((row) => row.key);
  if (keys.some((key) => state.diagnostics.has(key))) return "warning";
  if (keys.some((key) => managedOf(state, key) !== null)) return "lock";
  if (category === "agents" && harnessesNeedAttention(state.harnesses)) return "update";
  return null;
}

const BADGE_TEXT = {
  lock: "settingsPage.managed",
  update: "settingsWindow.harnesses.attention",
} as const;

/** The category list: icon, name, and a badge for problems (warning), managed keys (lock) or an
 * agent CLI that is outdated or signed out (update). */
export function SectionList({ current, onSelect }: { current: string | null; onSelect: (section: string) => void }) {
  const state = useSettingsState();
  return (
    <nav className="section-list" aria-label={t("settingsPage.sections")}>
      {shownCategories(state.host?.dev_build === true).map((category) => {
        const mark = badge(state, category.id);
        return (
          <button
            key={category.id}
            type="button"
            className="section-link"
            data-section-link={category.id}
            aria-current={category.id === current ? "page" : undefined}
            onClick={() => onSelect(category.id)}
          >
            <span className="section-icon" data-category={category.id}>
              <Icon name={category.symbol} />
            </span>
            <span className="section-name">{text(category.title)}</span>
            {mark && (
              <span className={`badge badge-${mark}`} data-badge={mark}>
                <Icon name={mark} />
                <span className="visually-hidden">
                  {mark === "warning" ? t("settingsPage.problems", settingsFileName(state.host)) : t(BADGE_TEXT[mark])}
                </span>
              </span>
            )}
          </button>
        );
      })}
    </nav>
  );
}
