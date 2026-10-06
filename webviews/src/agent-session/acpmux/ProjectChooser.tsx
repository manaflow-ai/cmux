import React, { useEffect, useId, useMemo, useRef, useState } from "react";
import { ChevronIcon } from "./ComposerPickers";
import { useT } from "./i18n";

export type Project = { cwd: string; label: string };

/// The project pill on the composer's tray: it opens a menu above the tray with a search field over the
/// projects the user has chats in, newest first. Picking one other than the current
/// project starts a new chat there. The search field keeps focus; arrows move the
/// highlight, Enter picks and Escape closes back to the pill.
export function ProjectChooser({
  projects,
  current,
  currentLabel,
  icon,
  onPick,
  onBrowse,
}: {
  projects: Project[];
  current?: string;
  currentLabel?: string;
  icon: React.ReactNode;
  onPick(cwd: string): void;
  onBrowse?(): void;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  // The highlighted project, by folder: the list re-sorts as chats update while the menu is open.
  const [active, setActive] = useState<string | undefined>(undefined);
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const menuId = useId();

  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return projects.filter((project) => {
      const text = `${project.label} ${project.cwd}`.toLowerCase();
      return words.every((word) => text.includes(word));
    });
  }, [projects, query]);
  const typedPath = useMemo(() => {
    const value = query.trim();
    return value.startsWith("/") || value.startsWith("~/") ? value : undefined;
  }, [query]);
  const selected = Math.max(
    0,
    shown.findIndex((project) => project.cwd === active),
  );

  const show = () => {
    setQuery("");
    setActive(current);
    setOpen(true);
  };
  const close = (refocus: boolean) => {
    setOpen(false);
    if (refocus) trigger.current?.focus();
  };
  const pick = (project: Project | undefined) => {
    const cwd = project?.cwd ?? typedPath;
    if (!cwd) return;
    // A new chat takes the focus to its prompt (Composer); the current project returns to the pill.
    const starts = cwd !== current;
    close(!starts);
    if (starts) onPick(cwd);
  };

  useEffect(() => {
    if (!open) return;
    search.current?.focus();
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const blur = () => setOpen(false);
    document.addEventListener("pointerdown", away);
    window.addEventListener("blur", blur);
    return () => {
      document.removeEventListener("pointerdown", away);
      window.removeEventListener("blur", blur);
    };
  }, [open]);

  const keyDown = (event: React.KeyboardEvent) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      close(true);
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (shown.length > 0)
        setActive(shown[(selected + (event.key === "ArrowDown" ? 1 : -1) + shown.length) % shown.length]!.cwd);
    } else if (event.key === "Enter") {
      event.preventDefault();
      pick(shown[selected]);
    }
  };

  return (
    <span
      ref={root}
      className="acpmux-picker acpmux-project"
      onBlur={(event) => {
        if (open && !root.current?.contains(event.relatedTarget as Node | null)) setOpen(false);
      }}
    >
      <button
        ref={trigger}
        type="button"
        className="acpmux-context-chip acpmux-project-button"
        aria-label={t("project.label")}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        title={current ? `${t("project.label")}: ${current}` : undefined}
        // WebKit doesn't focus a clicked button, so its mousedown would blur the open search
        // field and close the menu before this click reopened it.
        onMouseDown={(event) => {
          if (open) event.preventDefault();
        }}
        onClick={() => (open ? close(true) : show())}
      >
        {icon}
        <span>{currentLabel ?? t("project.choose")}</span>
        <ChevronIcon />
      </button>
      {open && (
        <div className="acpmux-menu acpmux-menu-start acpmux-project-menu">
          <div className="acpmux-project-search">
            <SearchIcon />
            <input
              ref={search}
              type="text"
              // A combobox that owns the project list: the role carries aria-expanded and aria-controls.
              // oxlint-disable-next-line jsx-a11y/no-redundant-roles
              role="combobox"
              aria-label={t("project.search")}
              aria-expanded="true"
              aria-controls={menuId}
              aria-autocomplete="list"
              aria-activedescendant={shown.length > 0 ? `${menuId}-${selected}` : undefined}
              placeholder={t("project.search")}
              value={query}
              spellCheck={false}
              autoComplete="off"
              onChange={(event) => {
                setQuery(event.target.value);
                setActive(undefined);
              }}
              onKeyDown={keyDown}
            />
          </div>
          <div
            id={menuId}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="listbox"
            aria-label={t("project.label")}
          >
            {shown.map((project, index) => (
              <div
                key={project.cwd}
                id={`${menuId}-${index}`}
                // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                role="option"
                tabIndex={-1}
                aria-selected={index === selected}
                aria-checked={project.cwd === current}
                aria-label={`${project.label}, ${project.cwd}`}
                className={`acpmux-menu-item${index === selected ? " acpmux-menu-active" : ""}`}
                title={project.cwd}
                onPointerMove={() => setActive(project.cwd)}
                onMouseDown={(event) => {
                  event.preventDefault();
                  pick(project);
                }}
              >
                {icon}
                <span className="acpmux-menu-text">
                  <span className="acpmux-menu-label">{project.label}</span>
                  <span className="acpmux-menu-description" data-path={project.cwd} />
                </span>
              </div>
            ))}
            {shown.length === 0 &&
              (typedPath ? (
                <button
                  type="button"
                  className="acpmux-menu-item acpmux-menu-active"
                  onMouseDown={(event) => {
                    event.preventDefault();
                    pick(undefined);
                  }}
                >
                  {icon}
                  <span className="acpmux-menu-label">{t("project.usePath", { path: typedPath })}</span>
                </button>
              ) : (
                <div className="acpmux-project-empty">{t("project.none")}</div>
              ))}
          </div>
          {onBrowse && (
            <button
              type="button"
              className="acpmux-project-browse"
              onMouseDown={(event) => {
                event.preventDefault();
                close(false);
                onBrowse();
              }}
            >
              {t("project.browse")}
            </button>
          )}
        </div>
      )}
    </span>
  );
}

function SearchIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      aria-hidden="true"
      focusable="false"
    >
      <circle cx="7" cy="7" r="4.25" />
      <path d="m10.25 10.25 3 3" />
    </svg>
  );
}
