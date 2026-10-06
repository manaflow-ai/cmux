import { useSettingsState } from "../context";
import { settingsFileName } from "../format";
import { Icon } from "../icons";
import { rowsInSection, sections } from "../schema";
import type { SettingsState } from "../store";
import { managedOf } from "../store";
import { t, text } from "../strings";

function badge(state: SettingsState, section: string): "warning" | "lock" | null {
  const keys = rowsInSection(section).map((row) => row.key);
  if (keys.some((key) => state.diagnostics.has(key))) return "warning";
  if (keys.some((key) => managedOf(state, key) !== null)) return "lock";
  return null;
}

/** The section list: icon, name, and a badge for problems (warning) or managed keys (lock). */
export function SectionList({ current, onSelect }: { current: string | null; onSelect: (section: string) => void }) {
  const state = useSettingsState();
  return (
    <nav className="section-list" aria-label={t("settingsPage.sections")}>
      {sections.map((section) => {
        const mark = badge(state, section.id);
        return (
          <button
            key={section.id}
            type="button"
            className="section-link"
            data-section-link={section.id}
            aria-current={section.id === current ? "page" : undefined}
            onClick={() => onSelect(section.id)}
          >
            <Icon name={section.symbol} />
            <span className="section-name">{text(section.title)}</span>
            {mark && (
              <span className={`badge badge-${mark}`} data-badge={mark}>
                <Icon name={mark} />
                <span className="visually-hidden">
                  {mark === "warning"
                    ? t("settingsPage.problems", settingsFileName(state.host))
                    : t("settingsPage.managed")}
                </span>
              </span>
            )}
          </button>
        );
      })}
    </nav>
  );
}
