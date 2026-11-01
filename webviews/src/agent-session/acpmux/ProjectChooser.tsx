import React, { useEffect, useMemo, useRef, useState } from "react";
import { ChevronIcon } from "./ComposerPickers";
import type { BrowseRequest, BrowseResult } from "./AddProjectPanel";
import { useT } from "./i18n";
import { Popover } from "../../ui/Popover";
import { Combobox } from "../../ui/Combobox";
import { AddProjectDialog } from "./AddProjectPanel";
import type { ProjectDirectoryHost } from "./projectDirectory";
import { ProjectBadge } from "./ProjectBadge";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { chooserRows, type ProjectRepo } from "./projectRepos";
import { machineColor } from "./machineColor";

/// A folder to start a chat in. `peer` (with its display name `host`) is another machine's folder:
/// its row carries the machine's computer, in the machine's own color, and its name, and a pick
/// starts the chat there. `repo` is the
/// folder's repository as this Mac's host read it (projectRepos.ts).
export type Project = {
  cwd: string;
  label: string;
  peer?: string;
  host?: string;
  repo?: ProjectRepo;
};

/// One row of the chooser: a project, or Do not work in a project (`project` undefined).
type Row = { key: string; project?: Project };

const NO_PROJECT_KEY = "\u0000none";
const rowKey = (project: Project) => (project.peer ? `${project.peer}\u0000${project.cwd}` : project.cwd);

/// The project pill on the composer's tray: it opens a menu above the tray with a search field over the
/// projects the user has chats in, newest first, one row per repository. Picking one other than the current
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
  onBrowse?(request?: BrowseRequest): Promise<BrowseResult> | BrowseResult | void;
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
  const trigger = useRef<HTMLButtonElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const currentKey = current
    ? rowKey({ cwd: current, label: "", ...(currentPeer ? { peer: currentPeer } : {}) })
    : undefined;

  // One row per repository; a lane's worktree or a scratch folder only when the search names it
  // (projectRepos.ts chooserRows).
  const shown = useMemo(
    () => chooserRows(projects, query, currentPeer ? undefined : current),
    [projects, query, current, currentPeer],
  );
  const rows = useMemo<Row[]>(() => {
    const listed: Row[] = shown.map((project) => ({ key: rowKey(project), project }));
    if (onNoProject) listed.unshift({ key: NO_PROJECT_KEY });
    return listed;
  }, [shown, onNoProject]);
  const rowsByKey = useMemo(() => new Map(rows.map((row) => [row.key, row])), [rows]);
  const isCurrent = (key: string) =>
    rowsByKey.has(key) && (key === currentKey || (noProject && key === NO_PROJECT_KEY));
  const typedPath = useMemo(() => {
    const value = query.trim();
    return value.startsWith("/") || value.startsWith("~/") ? value : undefined;
  }, [query]);
  const show = () => {
    setQuery("");
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

  const pinned = [...(onNoProject ? [NO_PROJECT_KEY] : []), ...(onBrowse ? [ADD_PROJECT_KEY] : [])];
  const suggestions = [...pinned, ...rows.filter((row) => row.key !== NO_PROJECT_KEY).map((row) => row.key)];
  if (typedPath && shown.length === 0) suggestions.push(typedPath);
  const rowLabel = (key: string) => {
    if (key === ADD_PROJECT_KEY) return t("project.new");
    const project = rowsByKey.get(key)?.project;
    return project
      ? [project.label, project.host, project.cwd].filter(Boolean).join(" ")
      : key === NO_PROJECT_KEY
        ? t("project.noProject")
        : key;
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
        // tooltip-allow: a truncated project label keeps its full path available.
        title={current}
        aria-expanded={open}
        {...press}
      >
        {!inline &&
          (current ? (
            <ProjectBadge project={{ cwd: current, label, ...(currentPeer ? { peer: currentPeer } : {}) }} />
          ) : (
            icon
          ))}
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
          <Combobox
            inputRef={search}
            suggestions={suggestions}
            pinnedSuggestions={pinned}
            onQuery={setQuery}
            onSubmit={(key) => {
              if (key === ADD_PROJECT_KEY) {
                close(false);
                setAdding(true);
                return;
              }
              const row =
                rowsByKey.get(key) ??
                (!key && !query.trim()
                  ? (rows.find(
                      (candidate) => candidate.key === currentKey || (noProject && candidate.key === NO_PROJECT_KEY),
                    ) ?? rows[0])
                  : undefined);
              if (row || (typedPath && key === typedPath)) pick(row);
            }}
            onCancel={() => close(true)}
            cancelOnBlur={false}
            autoHighlight
            label={t("project.search")}
            placeholder={t("project.search")}
            inputClassName="acpmux-project-search-field"
            listClassName="acpmux-project-folders m-0 list-none p-0"
            itemClassName="acpmux-menu-item rounded-lg data-[highlighted]:bg-hover"
            itemLabel={rowLabel}
            isItemCurrent={isCurrent}
            completionText={(key) => (key === NO_PROJECT_KEY ? "" : rowLabel(key))}
            renderItem={(key) => {
              if (key === ADD_PROJECT_KEY)
                return (
                  <>
                    <span className="acpmux-project-lead" aria-hidden="true">
                      <PlusIcon />
                    </span>
                    <span className="acpmux-menu-text">
                      <span className="acpmux-menu-label">{t("project.new")}</span>
                    </span>
                  </>
                );
              const row = rowsByKey.get(key);
              const project = row?.project;
              const checked = isCurrent(key);
              const name = project ? project.label : row ? t("project.noProject") : t("project.usePath", { path: key });
              return (
                <>
                  {project ? (
                    <ProjectBadge project={project} />
                  ) : (
                    <span className="acpmux-project-lead" aria-hidden="true">
                      {row ? <NoProjectIcon /> : icon}
                    </span>
                  )}
                  <span className="acpmux-menu-text">
                    <span className="acpmux-menu-label">{name}</span>
                    {project && !titledByPath(project) && (
                      <span className="acpmux-menu-description" data-path={project.cwd} />
                    )}
                  </span>
                  {project?.host && (
                    <span className="acpmux-project-host" data-peer={project.peer}>
                      <MachineIcon name={project.peer ? project.host : undefined} />
                      <span>{project.host}</span>
                    </span>
                  )}
                  <span className="acpmux-project-check" aria-hidden="true">
                    {checked ? "✓" : ""}
                  </span>
                </>
              );
            }}
            inline
          />
          {shown.length === 0 && !typedPath && (query.trim() || !onNoProject) && (
            <div className="acpmux-project-empty">{t(query.trim() ? "project.none" : "project.noneYet")}</div>
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

/// A folder the host names by its own path (a home folder has no project name): its title is
/// already the path, so the row shows it once (Leo, ":( alignemnt").
function titledByPath(project: Project) {
  const trim = (path: string) => path.trim().replace(/(.)\/+$/, "$1");
  return trim(project.label) === trim(project.cwd);
}

/// The machine a project is on: the computer the composer's chip and the environment list draw for
/// it, in that machine's own color (machineColor), so each machine reads as itself instead of one
/// globe repeated on every row (Leo, 2026-10-20: "we can have them be delineated rather than just
/// this is a computer symbol. This is a computer symbol"). This Mac stays quiet.
function MachineIcon({ name }: { name?: string }) {
  return (
    <svg
      className="acpmux-icon"
      style={name ? { color: machineColor(name) } : undefined}
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <rect x="3" y="3.5" width="10" height="7" rx="1.2" />
      <path d="M1.75 12.5h12.5" strokeLinecap="round" />
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

const ADD_PROJECT_KEY = "__add_project__";
