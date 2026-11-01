import { Link, type AnyRouter } from "@tanstack/react-router";
import { useSettingsState } from "../context";
import { categoryRows, shownSidebarSections, type Category } from "../categories";
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
 * agent CLI that is outdated or signed out (update). Each entry is a router link: hover or keyboard
 * focus preloads its section (the router's `defaultPreload: "intent"`), a click navigates.
 * `current` marks the shown category (null while searching); the link's own active match is exact,
 * so it never marks a section the page is not showing. */
export function SectionList({ current, onSelect }: { current: string | null; onSelect: (section: string) => void }) {
  const state = useSettingsState();
  const link = (category: Category) => {
    const mark = badge(state, category.id);
    return (
      <Link<AnyRouter, string, string>
        key={category.id}
        to="/settings/$section"
        params={{ section: category.id }}
        search={{}}
        activeOptions={{ exact: true }}
        activeProps={{}}
        className="section-link"
        draggable={false}
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
      </Link>
    );
  };
  // Each run of categories sits under its small header (Look and Feel, AI, ...), the layout the
  // Swift `SettingsPageLayout.sidebarSections` exports; the lead run (General, Updates) has none.
  return (
    <nav className="section-list" aria-label={t("settingsPage.sections")}>
      {shownSidebarSections(state.host?.dev_build === true).map(({ section, categories }) => {
        const headerId = `sidebar-section-${section.id}`;
        return (
          <div
            key={section.id}
            className="sidebar-section"
            data-sidebar-section={section.id}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a labelled group of sidebar links; a fieldset would bring its own box and form semantics
            role="group"
            aria-labelledby={section.title ? headerId : undefined}
          >
            {section.title && (
              <h3 className="sidebar-section-title" id={headerId}>
                {text(section.title)}
              </h3>
            )}
            {categories.map(link)}
          </div>
        );
      })}
    </nav>
  );
}
