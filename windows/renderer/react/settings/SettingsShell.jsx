import React, { useEffect, useRef } from "react";

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
  const tabTitleTemplate = labels.tabTitle || "{label}";

  return (
    <div className="settings-react-shell" data-react-settings="true">
      <div className={`settings-search${query ? " has-query" : ""}`}>
        <input
          aria-label={labels.searchPlaceholder}
          className="setting-control settings-search-input"
          type="search"
          placeholder={labels.searchPlaceholder}
          value={query}
          onChange={(event) => onQuery(event.target.value)}
        />
        <button
          aria-label={labels.clearSearch}
          className="settings-search-clear"
          type="button"
          disabled={!query}
          title={labels.clearSearch}
          onClick={onClear}
        >
          <span aria-hidden="true">×</span>
        </button>
      </div>
      <div className="settings-page-switcher">
        <div className="settings-page-head">
          <span className="settings-page-label">{labels.pageLabel}</span>
          <select
            aria-label={subtitle || labels.pageAriaLabel}
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
          aria-label={labels.pagesAriaLabel}
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
