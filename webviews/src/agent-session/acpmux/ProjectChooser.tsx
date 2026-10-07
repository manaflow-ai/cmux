import React, { useEffect, useId, useMemo, useRef, useState } from "react";
import { ChevronIcon } from "./ComposerPickers";
import { useT } from "./i18n";
import { Popover } from "../../ui/Popover";
import { usePopoverTrigger } from "./popoverTrigger";

export type Project = { cwd: string; label: string };

const BADGE_COLORS = [
  "var(--agent-ansi-4, #58a6ff)",
  "var(--agent-ansi-5, #bf7af0)",
  "var(--agent-ansi-6, #f2c94c)",
  "var(--agent-ansi-2, #32d74b)",
  "var(--agent-ansi-3, #ff9f0a)",
] as const;

function projectBadge(project: Project): { label: string; color: string } {
  const words = project.label.trim().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const label = (words.length > 1 ? words.map((word) => word[0]).join("") : project.label.trim()).slice(0, 2);
  let hash = 0;
  for (const character of project.cwd) hash = (hash * 31 + character.charCodeAt(0)) | 0;
  return { label: (label || "?").toUpperCase(), color: BADGE_COLORS[Math.abs(hash) % BADGE_COLORS.length]! };
}

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
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
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
  const press = usePopoverTrigger(open, (next) => (next ? show() : close(true)), show);
  const pick = (project: Project | undefined) => {
    const cwd = project?.cwd ?? typedPath;
    if (!cwd) return;
    // A new chat takes the focus to its prompt (Composer); the current project returns to the pill.
    const starts = cwd !== current;
    close(!starts);
    if (starts) onPick(cwd);
  };

  useEffect(() => {
    if (open) search.current?.focus();
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
    <span className="acpmux-picker acpmux-project">
      <button
        ref={trigger}
        type="button"
        className="acpmux-context-chip acpmux-project-button"
        aria-label={t("project.label")}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        title={current ? `${t("project.label")}: ${current}` : undefined}
        {...press}
      >
        {icon}
        <span>{currentLabel ?? t("project.choose")}</span>
        <ChevronIcon />
      </button>
      <Popover
        open={open}
        onOpenChange={(next) => (next ? show() : close(true))}
        anchor={open ? trigger.current : null}
        label={t("project.label")}
        className="acpmux-menu acpmux-project-menu"
        side="top"
        initialFocus={search}
        finalFocus={trigger}
      >
        <div ref={menu}>
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
                <ProjectBadge project={project} />
                <span className="acpmux-menu-text">
                  <span className="acpmux-menu-label">{project.label}</span>
                  <span className="acpmux-menu-description" data-path={project.cwd} />
                </span>
                <span className="acpmux-project-check" aria-hidden="true">
                  {project.cwd === current ? "✓" : ""}
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
      </Popover>
    </span>
  );
}

function ProjectBadge({ project }: { project: Project }) {
  const badge = projectBadge(project);
  return (
    <span className="acpmux-project-badge" style={{ "--acpmux-project-badge": badge.color } as React.CSSProperties} aria-hidden="true">
      {badge.label}
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
