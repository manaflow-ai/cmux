import React from "react";

export function SettingsShell({
  activeCategory,
  categories,
  query,
  subtitle,
  onCategory,
  onQuery,
  onClear
}) {
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
    </div>
  );
}
