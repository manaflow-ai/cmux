import React, { useEffect, useId, useMemo, useRef, useState } from "react";
import { ChevronIcon } from "./ComposerPickers";
import { useT } from "./i18n";
import { Popover } from "../../ui/Popover";
import { AddProjectDialog } from "./AddProjectPanel";
import type { ProjectDirectoryHost } from "./projectDirectory";
import { ProjectBadge } from "./ProjectBadge";
import { usePopoverTrigger } from "../../ui/popoverTrigger";

/// A folder to start a chat in. `peer` (with its display name `host`) is another machine's folder:
/// its row carries a globe and the machine's name, and a pick starts the chat there.
export type Project = { cwd: string; label: string; peer?: string; host?: string };

/// One row of the chooser: a project, or Do not work in a project (`project` undefined).
type Row = { key: string; project?: Project };

const NO_PROJECT_KEY = "\u0000none";
const rowKey = (project: Project) => (project.peer ? `${project.peer}\u0000${project.cwd}` : project.cwd);

/// The project pill on the composer's tray: it opens a menu above the tray with a search field over the
/// projects the user has chats in, newest first. Picking one other than the current
/// project starts a new chat there. The search field keeps focus; arrows move the
/// highlight, Enter picks and Escape closes back to the pill.
/// `inline` draws the trigger as the project's name inside a sentence (the new chat's "What should
/// we build in <project>?", cx-9g0w), and `onNoProject` adds Do not work in a project, checked while
/// `noProject`.
export function ProjectChooser({
  projects,
  current,
  currentPeer,
  currentLabel,
  icon,
  onPick,
  onBrowse,
  onNoProject,
  noProject = false,
  projectHost,
  side = "top",
  inline = false,
}: {
  projects: Project[];
  current?: string;
  /// The machine `current` is on; none for this Mac.
  currentPeer?: string;
  currentLabel?: string;
  icon: React.ReactNode;
  onPick(cwd: string, peer?: string): void;
  onBrowse?(): void;
  onNoProject?(): void;
  /// The chat is in no project: Do not work in a project is checked, and picking it changes nothing.
  noProject?: boolean;
  projectHost?: ProjectDirectoryHost;
  /// Where the menu opens: above the composer's tray, below a picker at the top of a page.
  side?: "top" | "bottom";
  inline?: boolean;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [adding, setAdding] = useState(false);
  const [query, setQuery] = useState("");
  // The highlighted row, by key: the list re-sorts as chats update while the menu is open.
  const [active, setActive] = useState<string | undefined>(undefined);
  const trigger = useRef<HTMLButtonElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const menuId = useId();
  const currentKey = current
    ? rowKey({ cwd: current, label: "", ...(currentPeer ? { peer: currentPeer } : {}) })
    : undefined;

  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return projects.filter((project) => {
      const text = `${project.label} ${project.cwd} ${project.host ?? ""}`.toLowerCase();
      return words.every((word) => text.includes(word));
    });
  }, [projects, query]);
  const rows = useMemo<Row[]>(() => {
    const listed: Row[] = shown.map((project) => ({ key: rowKey(project), project }));
    if (onNoProject && !query.trim()) listed.push({ key: NO_PROJECT_KEY });
    return listed;
  }, [shown, onNoProject, query]);
  const typedPath = useMemo(() => {
    const value = query.trim();
    return value.startsWith("/") || value.startsWith("~/") ? value : undefined;
  }, [query]);
  const selected = Math.max(
    0,
    rows.findIndex((row) => row.key === active),
  );

  const show = () => {
    setQuery("");
    setActive(currentKey ?? (onNoProject && noProject ? NO_PROJECT_KEY : undefined));
    setOpen(true);
  };
  const close = (refocus: boolean) => {
    setOpen(false);
    if (refocus) trigger.current?.focus();
  };
  const press = usePopoverTrigger(open, (next) => (next ? show() : close(true)), show);
  const pick = (row: Row | undefined) => {
    if (row && !row.project) {
      // Do not work in a project: a change unless the chat is in no project already.
      close(noProject);
      if (!noProject) onNoProject?.();
      return;
    }
    const cwd = row?.project?.cwd ?? typedPath;
    if (!cwd) return;
    // A new chat takes the focus to its prompt (Composer); the current project returns to the pill.
    const starts = (row?.key ?? cwd) !== currentKey;
    close(!starts);
    if (starts) onPick(cwd, row?.project?.peer);
  };

  useEffect(() => {
    if (!open) return;
    search.current?.focus();
    const blur = () => setOpen(false);
    window.addEventListener("blur", blur);
    return () => window.removeEventListener("blur", blur);
  }, [open]);

  const keyDown = (event: React.KeyboardEvent) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      close(true);
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (rows.length > 0)
        setActive(rows[(selected + (event.key === "ArrowDown" ? 1 : -1) + rows.length) % rows.length]!.key);
    } else if (event.key === "Enter") {
      event.preventDefault();
      pick(rows[selected]);
    }
  };

  const label = currentLabel ?? t("project.choose");
  return (
    <span className={`acpmux-picker acpmux-project${inline ? " acpmux-project-inline" : ""}`}>
      <button
        ref={trigger}
        type="button"
        className={inline ? "acpmux-project-button" : "acpmux-context-chip acpmux-project-button"}
        aria-label={inline ? `${t("project.label")}: ${label}` : t("project.label")}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        title={current ? `${t("project.label")}: ${current}` : undefined}
        {...press}
      >
        {!inline && icon}
        <span>{label}</span>
        <ChevronIcon />
      </button>
      <Popover
        open={open}
        onOpenChange={(next) => (next ? show() : close(true))}
        anchor={open ? trigger.current : null}
        label={t("project.label")}
        className="acpmux-menu acpmux-project-menu"
        side={side}
        initialFocus={search}
        finalFocus={false}
      >
        <div>
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
              aria-activedescendant={rows.length > 0 ? `${menuId}-${selected}` : undefined}
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
            {rows.map((row, index) => {
              const project = row.project;
              const checked = project ? row.key === currentKey : noProject;
              const name = project ? project.label : t("project.noProject");
              return (
                <div
                  key={row.key}
                  id={`${menuId}-${index}`}
                  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                  role="option"
                  tabIndex={-1}
                  aria-selected={index === selected}
                  aria-checked={checked}
                  aria-label={project ? [project.label, project.host, project.cwd].filter(Boolean).join(", ") : name}
                  className={`acpmux-menu-item${index === selected ? " acpmux-menu-active" : ""}${project ? "" : " acpmux-project-none"}`}
                  title={project?.cwd}
                  onPointerMove={() => setActive(row.key)}
                  onMouseDown={(event) => {
                    event.preventDefault();
                    pick(row);
                  }}
                >
                  {project ? <ProjectBadge project={project} /> : <NoProjectIcon />}
                  <span className="acpmux-menu-text">
                    <span className="acpmux-menu-label">{name}</span>
                    {project && <span className="acpmux-menu-description" data-path={project.cwd} />}
                  </span>
                  {project?.host && (
                    <span className="acpmux-project-host" title={project.host}>
                      <GlobeIcon />
                      <span>{project.host}</span>
                    </span>
                  )}
                  <span className="acpmux-project-check" aria-hidden="true">
                    {checked ? "✓" : ""}
                  </span>
                </div>
              );
            })}
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
                (query.trim() || !onNoProject) && <div className="acpmux-project-empty">{t("project.none")}</div>
              ))}
          </div>
          {onBrowse && (
            <button
              type="button"
              className="acpmux-project-browse"
              onMouseDown={(event) => {
                event.preventDefault();
                close(false);
                setAdding(true);
              }}
            >
              <PlusIcon />
              {t("project.new")}
            </button>
          )}
        </div>
      </Popover>
      <AddProjectDialog
        open={adding}
        host={projectHost}
        onBrowse={onBrowse}
        onClose={() => setAdding(false)}
        onPick={(cwd) => {
          setAdding(false);
          onPick(cwd);
        }}
      />
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

function GlobeIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      aria-hidden="true"
      focusable="false"
    >
      <circle cx="8" cy="8" r="5.75" />
      <path d="M2.25 8h11.5M8 2.25c-1.8 1.6-2.6 3.5-2.6 5.75S6.2 12.15 8 13.75M8 2.25c1.8 1.6 2.6 3.5 2.6 5.75S9.8 12.15 8 13.75" />
    </svg>
  );
}

function NoProjectIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-project-none-icon"
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
      <circle cx="8" cy="8" r="5.75" />
      <path d="m4 12 8-8" />
    </svg>
  );
}

function PlusIcon() {
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
      <path d="M8 3.5v9M3.5 8h9" />
    </svg>
  );
}
