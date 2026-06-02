import React, { useEffect, useRef } from "react";

const defaultLabels = {
  searchPlaceholder: "Search settings",
  clearSearch: "Clear search",
  pageLabel: "Page",
  pageAriaLabel: "Settings page",
  pagesAriaLabel: "Settings pages",
  tabTitle: "{label} settings"
};

export function SettingsShell({
  activeCategory,
  categories,
  query,
  subtitle,
  onCategory,
  onQuery,
  onClear,
  labels = {}
}) {
  const safeLabels = {
    searchPlaceholder: labels.searchPlaceholder || defaultLabels.searchPlaceholder,
    clearSearch: labels.clearSearch || defaultLabels.clearSearch,
    pageLabel: labels.pageLabel || defaultLabels.pageLabel,
    pageAriaLabel: labels.pageAriaLabel || defaultLabels.pageAriaLabel,
    pagesAriaLabel: labels.pagesAriaLabel || defaultLabels.pagesAriaLabel,
    tabTitle: labels.tabTitle || defaultLabels.tabTitle
  };
  const searchInputRef = useRef(null);
  const tabsRef = useRef(null);

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
    requestAnimationFrame(() => {
      searchInputRef.current?.focus({ preventScroll: true });
    });
  };
  const tabTitleTemplate = safeLabels.tabTitle || defaultLabels.tabTitle;

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
