import React, { useEffect, useRef } from "react";
import { formatMessage, t } from "../../i18n.js";

const defaultLabels = () => ({
  searchPlaceholder: t("settings.searchPlaceholder"),
  clearSearch: t("settings.clearSearch"),
  pageLabel: t("settings.pageLabel"),
  pageAriaLabel: t("settings.pageAriaLabel"),
  pagesAriaLabel: t("settings.pagesAriaLabel"),
  tabTitle: formatMessage("settings.tabTitle", { label: "{label}" })
});

export function SettingsShell({
  activeCategory,
  categories,
  focusSearchOnMount = false,
  query,
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
    pageLabel: labels.pageLabel || localizedDefaults.pageLabel,
    pageAriaLabel: labels.pageAriaLabel || localizedDefaults.pageAriaLabel,
    pagesAriaLabel: labels.pagesAriaLabel || localizedDefaults.pagesAriaLabel,
    tabTitle: labels.tabTitle || localizedDefaults.tabTitle
  };
  const searchInputRef = useRef(null);
  const tabsRef = useRef(null);

  useEffect(() => {
    if (focusSearchOnMount) searchInputRef.current?.focus({ preventScroll: true });
  }, [focusSearchOnMount]);

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
    onClear();
  };
  const tabTitleTemplate = safeLabels.tabTitle || localizedDefaults.tabTitle;

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
          <span aria-hidden="true">×</span>
        </button>
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
                {label}
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
