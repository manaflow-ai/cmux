import React, { useMemo, useRef, useState } from "react";
import { useNativePopup } from "../../ui/nativePopup";
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
/// them). The current folder is checked. Actions stay directly under search, before the scrolling
/// folders: No project, New Worktree, Add project and Choose folder, where the host offers them. The shared Combobox keeps the keyboard in the field:
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
  const { control, open, setOpen, side } = useLocationPopover();
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
  // Actions stay directly under search; Tab reaches them and arrows navigate the matching folders.
  const actions: { value: string; text: string; run(): void }[] = [
    ...(onNoProject ? [{ value: ACTION + "none", text: t("project.noProject"), run: onNoProject }] : []),
    ...(onNewWorktree ? [{ value: ACTION + "worktree", text: t("worktree.new"), run: onNewWorktree }] : []),
    ...(onBrowse
      ? [
          { value: ACTION + "add", text: t("project.add"), run: () => setAdding(true) },
          { value: ACTION + "browse", text: t("composer.chooseFolderMenu"), run: onBrowse },
        ]
      : []),
  ];
  const suggestions = [...actions.map((action) => action.value), ...shown.keys(), ...(typedPath ? [typedPath] : [])];
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
    if (action) action.run();
    else if (value && value !== current && (shown.has(value) || value === typedPath)) onPick(value);
  };
  useNativePopup({
    open,
    anchor: () => control.current,
    model: {
      side,
      align: "start",
      width: 380,
      title: label,
      search: { id: "query", value: query, placeholder: t("project.search") },
      rows:
        suggestions.length > 0
          ? suggestions.map((value) => {
              const action = actions.find((candidate) => candidate.value === value);
              if (action) {
                return {
                  id: value,
                  kind: "action" as const,
                  label: action.text,
                  checked: action.value === ACTION + "none" ? noProject : undefined,
                  icon: action.value === ACTION + "add" ? "plus" : action.value === ACTION + "none" ? "circle-slash" : "folder",
                };
              }
              const place = shown.get(value);
              if (!place) {
                return { id: value, kind: "action" as const, label: t("project.usePath", { path: value }), icon: "folder" };
              }
              const { group, worktree } = place;
              if (worktree) {
                return {
                  id: value,
                  kind: "action" as const,
                  label: worktreeName(worktree),
                  description: worktree.id,
                  checked: worktree.id === current,
                  icon: "branch",
                };
              }
              const folder = group.lead;
              const repo = folderRepo(folder);
              const suffix = repo && !isMainCheckout(folder) ? worktreeName(folder) : suffixes.get(folder.id);
              const others = group.members.length - 1;
              const groupOpen = expanded.has(group.key);
              return {
                id: value,
                kind: "action" as const,
                label: group.name,
                description: [suffix, folder.id].filter(Boolean).join(" · "),
                checked: folder.id === current,
                icon: "folder",
                actions:
                  others > 0 && !typed
                    ? [{ id: EXPAND + group.key, label: String(others), icon: "branch", keepOpen: true }]
                    : undefined,
                value: groupOpen ? "expanded" : undefined,
              };
            })
          : [{ id: "empty", kind: "text" as const, label: t(typed ? "project.none" : "project.noneYet") }],
      footer: note ? [{ id: "note", kind: "text" as const, label: note }] : undefined,
    },
    onEvent: (event) => {
      if (event.type === "search" && event.id === "query") setQuery(event.value ?? "");
      else if (event.type === "highlight" && event.id) highlighted.current = event.id;
      else if (event.type === "pick" && event.id) {
        if (event.id.startsWith(EXPAND)) {
          const key = event.id.slice(EXPAND.length);
          toggle(key, !expanded.has(key));
        } else submit(event.id);
      }
    },
    onDismiss: close,
  });

  return (
    <span ref={control} className="acpmux-location-picker">
      <button
        ref={trigger}
        type="button"
        className="acpmux-location-button ui-ghost ui-ghost-sm"
        aria-label={label}
        // tooltip-allow: the fixed footer column may truncate a long folder name.
        title={current}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...press}
      >
        {face}
      </button>
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
const EXPAND = "\u0000expand:";

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
