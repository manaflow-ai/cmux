import React, { useEffect, useRef } from "react";

export function SettingsShell({
  activeCategory,
  categories,
  query,
  subtitle,
  onCategory,
  onQuery,
  onClear
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

  return (
    <div className="settings-react-shell" data-react-settings="true">
      <div className="settings-search">
        <input
          className="setting-control settings-search-input"
          type="search"
          placeholder="Search settings"
          value={query}
          onChange={(event) => onQuery(event.target.value)}
        />
        <button
          aria-label="Clear search"
          className="settings-search-clear"
          type="button"
          disabled={!query}
          title="Clear search"
          onClick={onClear}
        >
          x
        </button>
      </div>
      <div className="settings-page-switcher">
        <div className="settings-page-head">
          <span className="settings-page-label">Page</span>
          <select
            aria-label={subtitle || "Settings page"}
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
          aria-label="Settings pages"
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
                title={`${label} settings`}
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
