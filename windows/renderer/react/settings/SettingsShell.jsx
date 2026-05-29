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
      <div className="settings-nav" role="tablist" aria-label={subtitle || "Settings pages"}>
        {categories.map(([id, label]) => (
          <button
            key={id}
            className={`settings-nav-button${activeCategory === id ? " is-active" : ""}`}
            type="button"
            role="tab"
            aria-selected={activeCategory === id}
            onClick={() => onCategory(id)}
          >
            {label}
          </button>
        ))}
      </div>
    </div>
  );
}
