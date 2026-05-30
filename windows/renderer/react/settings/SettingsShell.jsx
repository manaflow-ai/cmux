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
  const navRef = React.useRef(null);

  React.useEffect(() => {
    const activeButton = navRef.current?.querySelector(".settings-nav-button.is-active");
    if (!activeButton) return;
    activeButton.scrollIntoView({
      block: "nearest",
      inline: "center",
      behavior: document.body?.classList.contains("reduce-motion") ? "auto" : "smooth"
    });
  }, [activeCategory, categories]);

  React.useEffect(() => {
    const nav = navRef.current;
    if (!nav) return undefined;
    const onWheel = (event) => {
      if (event.ctrlKey || nav.scrollWidth <= nav.clientWidth) return;
      const horizontalDelta = event.deltaX || event.deltaY;
      if (!horizontalDelta) return;
      event.preventDefault();
      nav.scrollLeft += horizontalDelta;
    };
    nav.addEventListener("wheel", onWheel, { passive: false });
    return () => nav.removeEventListener("wheel", onWheel);
  }, []);

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
      <div ref={navRef} className="settings-nav" role="tablist" aria-label={subtitle || "Settings pages"}>
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
