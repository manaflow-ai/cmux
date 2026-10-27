import React, { useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { Popover } from "../../ui/Popover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { AddProjectDialog } from "./AddProjectPanel";
import { translate as t } from "./i18n";
import { useLocationOpener, useLocationPopover } from "./locationPopover";
import { ProjectBadge } from "./ProjectBadge";
import { projectSuffixes } from "./projectSuffix";
import { folderRepo, groupByRepo, isMainCheckout, shownRepoRows, worktreeName, type ProjectRepo } from "./projectRepos";

/// A folder the popover offers: its path (`id`), name and, when known, its repository.
export type FolderChoice = { id: string; label: string; repo?: ProjectRepo };

/// The new chat's folder popover (hq#1957 composer location strip): a search field over the
/// projects, one row per repository (projectRepos.ts: a repository's worktrees are its branches, not
/// projects of their own), named by the repository and, dimmed, the worktree's branch or, only when
/// another shares that name, a short suffix that tells it apart (projectSuffix.ts); the full path is
/// the row's tooltip. A repository's row picks the current folder, else its main checkout, else its
/// newest worktree; its other worktrees, newest first, open under it with → (← or the count closes
/// them). The current folder is checked. After the folders: New Worktree, Add project and Choose
/// folder…, each only where the host offers it. The shared Combobox keeps the keyboard in the field:
/// typing filters by repository, branch and path, and lists a worktree on its own when the words
/// name it; ↑/↓ move through the rows and the actions; Return picks; Escape closes back to the
/// strip. A typed absolute or `~/` path is offered as typed. `note` is a quiet line under the list:
/// where the chat starts while no folder is picked (a new chat's private folder).
export function FolderPopover({
  label,
  menu,
  face,
  folders,
  current,
  onPick,
  onBrowse,
  onNewWorktree,
  onNoProject,
  noProject = false,
  localName,
  peers,
  note,
}: {
  label: string;
  /// The name automation opens it by (`openPicker`).
  menu: string;
  /// The strip control's face (icon, name, chevron).
  face: React.ReactNode;
  folders: FolderChoice[];
  current?: string;
  onPick(cwd: string): void;
  /// The host's folder panel: Add project's Browse and Choose folder….
  onBrowse?(): void;
  /// New Worktree of the current folder.
  onNewWorktree?(): void;
  /// Do not work in a project (Leo 2026-10-18, as ChatGPT and Claude Code offer): the chat starts
  /// in no project. Checked while `noProject`.
  onNoProject?(): void;
  noProject?: boolean;
  localName?: string;
  peers?: string[];
  /// A quiet line under the list.
  note?: string;
}) {
  const [adding, setAdding] = useState(false);
  const [query, setQuery] = useState("");
  // The repositories whose worktrees are open under their row, by group key.
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const highlighted = useRef<string | undefined>(undefined);
  const trigger = useRef<HTMLButtonElement>(null);
  // Escape (not a blur) closes back to the strip's control.
  const escaped = useRef(false);
  const { control, anchor, open, setOpen, side } = useLocationPopover();
  const press = usePopoverTrigger(open, (next) => {
    setOpen(next);
    if (!next) {
      setQuery("");
      setExpanded(new Set());
    }
  });
  useLocationOpener(menu, () => setOpen(true));
  const groups = useMemo(() => groupByRepo(folders, current), [folders, current]);
  // Repositories that share a name (two clones both called "cmux") are told apart by their path.
  const suffixes = useMemo(
    () => projectSuffixes(groups.map((group) => ({ cwd: group.lead.id, label: group.name }))),
    [groups],
  );
  const rows = useMemo(() => shownRepoRows(groups, query, expanded), [groups, query, expanded]);
  // Each shown folder's row: a repository's (`group` only) or a worktree's under it.
  const shown = useMemo(() => {
    const byValue = new Map<string, { group: (typeof groups)[number]; worktree?: FolderChoice }>();
    for (const { group, worktrees } of rows) {
      byValue.set(group.lead.id, { group });
      for (const worktree of worktrees) byValue.set(worktree.id, { group, worktree });
    }
    return byValue;
  }, [rows]);
  const toggle = (key: string, open: boolean) =>
    setExpanded((before) => {
      if (before.has(key) === open) return before;
      const next = new Set(before);
      if (open) next.add(key);
      else next.delete(key);
      return next;
    });
  const typed = query.trim();
  const typedPath = /^(?:\/|~\/)/.test(typed) && !shown.has(typed) ? typed : undefined;
  // The actions follow the folders in the same list, so the arrows reach them from the field.
  const actions: { value: string; text: string; run(): void | Promise<unknown> }[] = [
    ...(onNoProject ? [{ value: ACTION + "none", text: t("project.noProject"), run: onNoProject }] : []),
    ...(onNewWorktree ? [{ value: ACTION + "worktree", text: t("worktree.new"), run: onNewWorktree }] : []),
    ...(onBrowse
      ? [
          { value: ACTION + "add", text: t("project.add"), run: () => setAdding(true) },
          { value: ACTION + "browse", text: t("composer.chooseFolderMenu"), run: onBrowse },
        ]
      : []),
  ];
  const suggestions = [...shown.keys(), ...(typedPath ? [typedPath] : []), ...actions.map((action) => action.value)];
  const close = () => {
    setOpen(false);
    setQuery("");
    setExpanded(new Set());
    if (escaped.current) trigger.current?.focus();
    escaped.current = false;
  };
  const submit = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    close();
    if (action) void Promise.resolve(action.run()).catch(() => undefined);
    else if (value && value !== current && (shown.has(value) || value === typedPath)) onPick(value);
  };
  const row = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    if (action)
      return (
        <span
          className="acpmux-location-action"
          data-first={action === actions[0] ? "" : undefined}
          data-choose={action.value === ACTION + "browse" ? "" : undefined}
        >
          <span className="acpmux-menu-label">{action.text}</span>
          {action.value === ACTION + "none" && (
            <span className="acpmux-location-check" aria-hidden="true">
              {noProject && <CheckIcon />}
            </span>
          )}
        </span>
      );
    const place = shown.get(value);
    if (!place)
      return (
        <span className="acpmux-location-row">
          <span className="acpmux-menu-label">{t("project.usePath", { path: value })}</span>
        </span>
      );
    const { group, worktree } = place;
    if (worktree)
      return (
        <span
          className="acpmux-location-row"
          // tooltip-allow: the row shows the worktree's branch; the tooltip is its full path
          title={worktree.id}
          data-worktree=""
          data-current={worktree.id === current ? "" : undefined}
        >
          <span className="acpmux-location-branch-icon" aria-hidden="true">
            <BranchIcon />
          </span>
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{worktreeName(worktree)}</span>
          </span>
          <span className="acpmux-location-check" aria-hidden="true">
            {worktree.id === current && <CheckIcon />}
          </span>
        </span>
      );
    const folder = group.lead;
    const repo = folderRepo(folder);
    // A worktree or subfolder leading its row is named by its branch or path; the main checkout needs none.
    const suffix = repo && !isMainCheckout(folder) ? worktreeName(folder) : suffixes.get(folder.id);
    const others = group.members.length - 1;
    const open = expanded.has(group.key);
    return (
      <span
        className="acpmux-location-row"
        // tooltip-allow: the row shows the folder's name; the tooltip is its full path
        title={folder.id}
        data-current={folder.id === current ? "" : undefined}
        data-expanded={others > 0 && !typed ? String(open) : undefined}
      >
        <ProjectBadge project={{ cwd: folder.id, label: folder.label, ...(repo ? { repo } : {}) }} />
        <span className="acpmux-menu-text acpmux-location-name">
          <span className="acpmux-menu-label">{group.name}</span>
          {suffix && (
            <>
              {" "}
              <span className="acpmux-location-suffix-dot" aria-hidden="true">
                ·
              </span>{" "}
              <span className="acpmux-location-suffix">{suffix}</span>
            </>
          )}
        </span>
        {others > 0 && !typed && (
          // The count opens or closes the repository's other worktrees; a press here never picks
          // the row (the arrows do the same from the field).
          <span
            className="acpmux-location-worktrees"
            aria-hidden="true"
            data-open={open ? "" : undefined}
            onPointerDown={(event) => {
              event.preventDefault();
              event.stopPropagation();
            }}
            onPointerUp={(event) => event.stopPropagation()}
            onMouseDown={(event) => event.stopPropagation()}
            onMouseUp={(event) => event.stopPropagation()}
            onClick={(event) => {
              event.preventDefault();
              event.stopPropagation();
              toggle(group.key, !open);
            }}
          >
            <BranchIcon />
            {others}
            <ChevronRightIcon />
          </span>
        )}
        <span className="acpmux-location-check" aria-hidden="true">
          {folder.id === current && <CheckIcon />}
        </span>
      </span>
    );
  };
  // → opens the highlighted repository's worktrees and ← closes them, while the field is empty
  // (with words typed the arrows move the caret).
  const arrow = (key: string) => {
    if (typed || (key !== "ArrowRight" && key !== "ArrowLeft")) return false;
    const place = highlighted.current ? shown.get(highlighted.current) : undefined;
    if (!place || place.group.members.length < 2) return false;
    const open = key === "ArrowRight";
    // Only from the repository's own row: collapsing under a worktree row would drop the highlight.
    if (!open && place.worktree) return false;
    if (expanded.has(place.group.key) === open) return false;
    toggle(place.group.key, open);
    return true;
  };

  return (
    <span ref={control} className="acpmux-location-picker">
      <button
        ref={trigger}
        type="button"
        className="acpmux-location-button ui-ghost ui-ghost-sm"
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...press}
      >
        {face}
      </button>
      <Popover
        open={open}
        onOpenChange={(next) => {
          setOpen(next);
          if (!next) setQuery("");
        }}
        anchor={open ? anchor : null}
        label={label}
        className="acpmux-menu acpmux-location-menu acpmux-folder-popover"
        side={side}
        flip={false}
        finalFocus={false}
      >
        <Combobox
          suggestions={suggestions}
          onQuery={setQuery}
          onSubmit={submit}
          onCancel={close}
          onHighlight={(value) => {
            highlighted.current = value;
          }}
          // Tab completes a folder's path into the field, never an action's.
          onCommand={(event) => {
            if (event.key === "Escape") escaped.current = true;
            if (arrow(event.key)) event.preventDefault();
            if (event.key === "Tab" && highlighted.current?.startsWith(ACTION)) event.preventDefault();
          }}
          label={t("project.search")}
          placeholder={t("project.search")}
          inputClassName="acpmux-location-search"
          listClassName="acpmux-location-folders"
          itemClassName="acpmux-menu-item"
          renderItem={row}
          autoHighlight
          inline
        />
        {shown.size === 0 && !typedPath && (
          <div className="acpmux-location-empty">{t(typed ? "project.none" : "project.noneYet")}</div>
        )}
        {note && <p className="acpmux-location-note">{note}</p>}
      </Popover>
      <AddProjectDialog
        open={adding}
        localName={localName}
        peers={peers}
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

/// An action row's value: never a path.
const ACTION = "\u0000action:";

function CheckIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="m3.5 8.5 3 3 6-7" />
    </svg>
  );
}

function BranchIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <circle cx="4.5" cy="3.5" r="1.5" />
      <circle cx="4.5" cy="12.5" r="1.5" />
      <circle cx="11.5" cy="5.5" r="1.5" />
      <path d="M4.5 5v6M11.5 7c0 2.5-2 3-7 4" />
    </svg>
  );
}

function ChevronRightIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={10}
      height={10}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="m6 3.5 4.5 4.5L6 12.5" />
    </svg>
  );
}
