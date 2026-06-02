import React, { useEffect, useRef } from "react";
import { formatMessage, t } from "../../i18n.js";

const defaultLabels = () => ({
  searchPlaceholder: t("settings.searchPlaceholder"),
  clearSearch: t("settings.clearSearch"),
  searchHint: t("settings.searchHint"),
  pageLabel: t("settings.pageLabel"),
  pageAriaLabel: t("settings.pageAriaLabel"),
  pagesAriaLabel: t("settings.pagesAriaLabel"),
  tabTitle: formatMessage("settings.tabTitle", { label: "{label}" })
});

function CloseIcon() {
  return (
    <svg aria-hidden="true" focusable="false" viewBox="0 0 24 24">
      <path d="m7 7 10 10M17 7 7 17" />
    </svg>
  );
}

const categoryIconPaths = {
    actions: (
      <>
        <path d="M8 7h8M8 12h5M8 17h8" />
        <path d="M4 7h.01M4 12h.01M4 17h.01" />
      </>
    ),
    appearance: (
      <>
        <path d="M12 4c4 0 8 3 8 7 0 3-2 5-5 5h-1.5a1.5 1.5 0 0 0 0 3H12a8 8 0 1 1 0-16Z" />
        <circle cx="8.5" cy="10" r="1" />
        <circle cx="12" cy="8" r="1" />
        <circle cx="15.5" cy="10" r="1" />
      </>
    ),
    blueprints: (
      <>
        <rect x="5" y="4" width="14" height="16" rx="2" />
        <path d="M8 8h8M8 12h5M8 16h6" />
      </>
    ),
    browser: (
      <>
        <circle cx="12" cy="12" r="8" />
        <path d="M4 12h16M12 4c2.2 2.3 2.2 13.7 0 16M12 4c-2.2 2.3-2.2 13.7 0 16" />
      </>
    ),
    commands: (
      <>
        <rect x="4" y="5" width="16" height="14" rx="2" />
        <path d="m8 10 3 3-3 3" />
        <path d="M13 16h3" />
      </>
    ),
    data: (
      <>
        <ellipse cx="12" cy="6" rx="7" ry="3" />
        <path d="M5 6v6c0 1.7 3.1 3 7 3s7-1.3 7-3V6" />
        <path d="M5 12v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6" />
      </>
    ),
    layout: (
      <>
        <rect x="4" y="5" width="16" height="14" rx="2" />
        <path d="M12 5v14M4 12h16" />
      </>
    ),
    performance: (
      <>
        <path d="M5 16a7 7 0 0 1 14 0" />
        <path d="m12 16 4-5" />
        <path d="M8 20h8" />
      </>
    ),
    profiles: (
      <>
        <circle cx="12" cy="8" r="3" />
        <path d="M5 20c1.2-4 12.8-4 14 0" />
      </>
    ),
    quick: (
      <>
        <path d="M5 12h14" />
        <path d="m13 6 6 6-6 6" />
        <path d="M5 6h4M5 18h4" />
      </>
    ),
    terminal: (
      <>
        <rect x="4" y="5" width="16" height="14" rx="2" />
        <path d="m8 10 3 3-3 3" />
        <path d="M13 16h3" />
      </>
    ),
    workspace: (
      <>
        <rect x="4" y="5" width="6" height="6" rx="1" />
        <rect x="14" y="5" width="6" height="6" rx="1" />
        <rect x="4" y="15" width="16" height="4" rx="1" />
      </>
    )
};

function CategoryIcon({ id }) {
  return (
    <svg aria-hidden="true" focusable="false" viewBox="0 0 24 24">
      {categoryIconPaths[id] || categoryIconPaths.quick}
    </svg>
  );
}

export function SettingsShell({
  activeCategory,
  categories,
  focusSearchOnMount = false,
  query,
  searchFeedback,
  subtitle,
  onCategory,
  onQuery,
  onClear,
  labels = {}
}) {
  const localizedDefaults = defaultLabels();
  const safeLabels = {
    searchPlaceholder: labels.searchPlaceholder || localizedDefaults.searchPlaceholder,
    clearSearch: labels.clearSearch || localizedDefaults.clearSearch,
    searchHint: labels.searchHint || localizedDefaults.searchHint,
    pageLabel: labels.pageLabel || localizedDefaults.pageLabel,
    pageAriaLabel: labels.pageAriaLabel || localizedDefaults.pageAriaLabel,
    pagesAriaLabel: labels.pagesAriaLabel || localizedDefaults.pagesAriaLabel,
    tabTitle: labels.tabTitle || localizedDefaults.tabTitle
  };
  const searchInputRef = useRef(null);
  const restoreSearchFocusAfterClearRef = useRef(false);
  const tabsRef = useRef(null);

  useEffect(() => {
    if (focusSearchOnMount) searchInputRef.current?.focus({ preventScroll: true });
  }, [focusSearchOnMount]);

  useEffect(() => {
    if (!restoreSearchFocusAfterClearRef.current || query) return;
    restoreSearchFocusAfterClearRef.current = false;
    searchInputRef.current?.focus({ preventScroll: true });
  }, [query]);

  useEffect(() => {
    tabsRef.current
      ?.querySelector(`[data-settings-category="${activeCategory}"]`)
      ?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [activeCategory]);

  const onTabsWheel = (event) => {
    if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
    event.currentTarget.scrollLeft += event.deltaY;
    event.preventDefault();
  };
  const clearSearch = () => {
    if (!query) return;
    restoreSearchFocusAfterClearRef.current = true;
    onClear();
  };
  const tabTitleTemplate = safeLabels.tabTitle || localizedDefaults.tabTitle;
  const feedbackText = searchFeedback || safeLabels.searchHint;

  return (
    <div className="settings-react-shell" data-react-settings="true">
      <div className={`settings-search${query ? " has-query" : ""}`}>
        <input
          aria-label={safeLabels.searchPlaceholder}
          className="setting-control settings-search-input"
          type="search"
          placeholder={safeLabels.searchPlaceholder}
          ref={searchInputRef}
          value={query}
          onChange={(event) => onQuery(event.target.value)}
        />
        <button
          aria-label={safeLabels.clearSearch}
          className="settings-search-clear"
          type="button"
          disabled={!query}
          title={safeLabels.clearSearch}
          onClick={clearSearch}
        >
          <CloseIcon />
        </button>
        <div className="settings-search-feedback" aria-live="polite" data-settings-search-feedback="true">
          {feedbackText}
        </div>
      </div>
      <div className="settings-page-switcher">
        <div className="settings-page-head">
          <span className="settings-page-label">{safeLabels.pageLabel}</span>
          <select
            aria-label={subtitle || safeLabels.pageAriaLabel}
            className="setting-select settings-page-select"
            value={activeCategory}
            onChange={(event) => onCategory(event.target.value)}
          >
            {categories.map(([id, label]) => (
              <option key={id} value={id}>
                {label}
              </option>
            ))}
          </select>
        </div>
        <div
          aria-label={safeLabels.pagesAriaLabel}
          className="settings-page-tabs"
          onWheel={onTabsWheel}
          ref={tabsRef}
          role="tablist"
        >
          {categories.map(([id, label]) => {
            const active = id === activeCategory;
            return (
              <button
                aria-selected={active ? "true" : "false"}
                className={`settings-page-tab${active ? " is-active" : ""}`}
                data-settings-category={id}
                key={id}
                onClick={() => onCategory(id)}
                role="tab"
                title={tabTitleTemplate.replace("{label}", label)}
                type="button"
              >
                <span className="settings-page-tab-icon" aria-hidden="true">
                  <CategoryIcon id={id} />
                </span>
                <span className="settings-page-tab-label">{label}</span>
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
