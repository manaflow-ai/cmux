import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Button } from "../../ui/Button";
import { Combobox } from "../../ui/Combobox";
import { Popover } from "../../ui/Popover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import type { BrowseRequest } from "./AddProjectPanel";
import type { BrowseResult } from "./addProjectPanelModel";
import { ExtraFolderList } from "./ExtraFolderList";
import type { ExtraFolderRows } from "./extraFolders";
import { GitHubInstallCard, GitHubMark, LockIcon } from "./GitHubInstallCard";
import { githubFolder, githubFolderRepo, matchingRepos, type GitHubPicker } from "./githubRepos";
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
/// them). The current folder is checked. The actions sit under the scrolling folders, each with its
/// glyph (Leo, 2026-11-06: "it's just folder / that's your project"): Add folder…, Add another folder…, New Worktree and No
/// folder last, where the host offers them.
/// A folder is the one thing the menu picks (Leo, 2026-11-06: "what even is the deal with add
/// project? ... why not just add fodler? what's special about project?"): Add folder… is the host's
/// folder panel, and a folder picked there is listed with the others from then on. The shared
/// Combobox keeps the keyboard in the field:
/// typing filters by repository, branch and path, and lists a worktree on its own when the words
/// name it; ↑/↓ move through the rows and the actions; Return picks; Escape closes back to the
/// strip. A typed absolute or `~/` path is offered as typed. `note` is a quiet line under the list:
/// where the chat starts while no folder is picked (a new chat's private folder).
/// `github` (a new Cloud chat only, githubRepos.ts) adds the person's GitHub repositories under the
/// folders: a GitHub group, filtered by the same search, whose pick is the folder `github:owner/name`;
/// before the cmux GitHub App is installed, one Add repositories from GitHub row that turns the menu
/// into the install card (Escape or Back returns to the list).
export function FolderPopover({
  label,
  menu,
  face,
  folders,
  current,
  onPick,
  onBrowse,
  onNewWorktree,
  onNewProject,
  onNoProject,
  noProject = false,
  note,
  extra,
  github,
}: {
  label: string;
  /// The name automation opens it by (`openPicker`).
  menu: string;
  /// The strip control's face (icon, name, chevron).
  face: React.ReactNode;
  folders: FolderChoice[];
  current?: string;
  onPick(cwd: string): void;
  /// The host's folder panel: Add folder….
  onBrowse?(request?: BrowseRequest): Promise<BrowseResult> | BrowseResult | void;
  /// New Worktree of the current folder.
  onNewWorktree?(): void;
  /// New Project: the chat starts in a new folder with an empty git repository (newtab/newProject.ts).
  onNewProject?(): void;
  /// No folder (Leo 2026-10-18): the chat starts in no folder of
  /// the user's (its private one). Checked while `noProject`.
  onNoProject?(): void;
  noProject?: boolean;
  /// A quiet line under the list.
  note?: string;
  /// The new chat's extra folders (extraFolders.ts): Add another folder… turns the list into a pick
  /// of one more folder the chat sees beside its own, and the ones added are listed under it.
  extra?: ExtraFolderRows;
  /// A new Cloud chat's GitHub repositories (githubRepos.ts); none for any other chat.
  github?: GitHubPicker;
}) {
  // Add another folder… was chosen: a pick adds a folder the chat also sees instead of moving the chat.
  const [addingExtra, setAddingExtra] = useState(false);
  const [query, setQuery] = useState("");
  // Add repositories from GitHub was chosen: the install card stands in for the list until the
  // status says ready, Back or Escape, or the menu closes.
  const [githubCard, setGitHubCard] = useState(false);
  // Back from the card (Back, Escape, or the status turning ready while it waited): the list's fresh
  // field takes the keyboard as it mounts.
  const refocusField = useRef(false);
  const fieldMounted = useCallback(
    (node: HTMLInputElement | null) => {
      if (!node || (!refocusField.current && !githubCard)) return;
      refocusField.current = false;
      node.focus();
    },
    [githubCard],
  );
  // The repositories whose worktrees are open under their row, by group key.
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const highlighted = useRef<string | undefined>(undefined);
  const [highlightAuto, setHighlightAuto] = useState(true);
  const trigger = useRef<HTMLButtonElement>(null);
  // Escape (not a blur) closes back to the strip's control.
  const escaped = useRef(false);
  const { control, anchor, open, setOpen: setPopoverOpen, side, flip } = useLocationPopover();
  const setOpen = (next: boolean) => {
    if (next) {
      setHighlightAuto(true);
      // Each open reads whether GitHub is connected, and its repositories once it is.
      if (!open) github?.onOpen();
    } else setGitHubCard(false);
    setPopoverOpen(next);
  };
  const press = usePopoverTrigger(open, (next) => {
    setOpen(next);
    if (!next) {
      setQuery("");
      setExpanded(new Set());
      setAddingExtra(false);
    }
  });
  useLocationOpener(menu, () => setOpen(true));
  // Add another folder… gives the menu a fresh field (the Combobox's key): the keyboard stays in it.
  useEffect(() => {
    if (!addingExtra) return;
    trigger.current?.ownerDocument
      .querySelector<HTMLInputElement>(".acpmux-folder-popover .acpmux-location-search")
      ?.focus();
  }, [addingExtra]);
  const extraFolders = extra?.folders;
  // While adding, the project and the folders already added are not offered again.
  const offered = useMemo(
    () =>
      addingExtra ? folders.filter((folder) => folder.id !== current && !extraFolders?.includes(folder.id)) : folders,
    [addingExtra, folders, current, extraFolders],
  );
  const groups = useMemo(() => groupByRepo(offered, current), [offered, current]);
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
  // The GitHub part: a pick of one more folder (Add another folder…) never lists repositories.
  const githubStatus = !addingExtra ? github?.state.status?.state : undefined;
  const cardShown = githubCard && githubStatus === "not_connected";
  const githubReady = githubStatus === "ready" && github?.state.error === undefined;
  const githubRepoList = github?.state.repos;
  const repos = useMemo(
    () => (githubReady && githubRepoList ? matchingRepos(githubRepoList, typed) : []),
    [githubReady, githubRepoList, typed],
  );
  const githubRows = [
    ...(githubStatus === "not_connected" ? [GITHUB_ADD] : []),
    ...repos.map((repo) => GITHUB_REPO + repo.fullName),
    ...(githubReady && github?.state.status?.reposScope === "selected" ? [GITHUB_MORE] : []),
  ];
  const repoRows = useMemo(() => new Map(repos.map((repo) => [GITHUB_REPO + repo.fullName, repo])), [repos]);
  const currentRepo = githubFolderRepo(current);
  // Actions stay under the folders; the arrows reach them after the last folder.
  const actions: {
    value: string;
    text: string;
    run(): Promise<BrowseResult> | BrowseResult | void;
  }[] = addingExtra
    ? extra?.onBrowse
      ? [
          {
            value: ACTION + "browse",
            text: t("composer.addFolder"),
            run: () =>
              Promise.resolve(extra.onBrowse?.()).then((path) => {
                if (typeof path === "string" && path) extra.onAdd(path);
                return undefined;
              }),
          },
        ]
      : []
    : [
        ...(onBrowse ? [{ value: ACTION + "browse", text: t("composer.addFolder"), run: onBrowse }] : []),
        ...(extra
          ? [{ value: ACTION_EXTRA, text: t("composer.addAnotherFolder"), run: () => setAddingExtra(true) }]
          : []),
        ...(onNewWorktree ? [{ value: ACTION + "worktree", text: t("worktree.new"), run: onNewWorktree }] : []),
        ...(onNewProject ? [{ value: ACTION + "project", text: t("project.new"), run: onNewProject }] : []),
        ...(onNoProject ? [{ value: ACTION + "none", text: t("project.noFolder"), run: onNoProject }] : []),
      ];
  const pinned = actions.map((action) => action.value);
  const suggestions = [...pinned, ...shown.keys(), ...(typedPath ? [typedPath] : []), ...githubRows];
  const close = () => {
    setOpen(false);
    setGitHubCard(false);
    setQuery("");
    setExpanded(new Set());
    setAddingExtra(false);
    if (escaped.current) trigger.current?.focus();
    escaped.current = false;
  };
  const submit = (value: string) => {
    // Add repositories from GitHub keeps the menu open on its install card.
    if (value === GITHUB_ADD) {
      setGitHubCard(true);
      return;
    }
    // Return on words no loaded repository matches: ask GitHub for them (the loaded page may be
    // only the first of the person's repositories).
    // Choose more repositories… is then the only row, highlighted by the typing, not by the person.
    if (
      githubReady &&
      typed &&
      !typedPath &&
      repos.length === 0 &&
      github?.state.truncated &&
      (value === query || (value === GITHUB_MORE && highlightAuto))
    ) {
      github.onSearch(typed);
      return;
    }
    // Add another folder… keeps the menu open: its list now adds a folder.
    if (value === ACTION_EXTRA) {
      setAddingExtra(true);
      setQuery("");
      setExpanded(new Set());
      return;
    }
    const action = actions.find((candidate) => candidate.value === value);
    const addsExtra = addingExtra;
    close();
    if (addsExtra && !action) {
      if (value && (shown.has(value) || value === typedPath)) extra?.onAdd(value);
      return;
    }
    if (action)
      void Promise.resolve()
        .then(() => action.run())
        .catch(() => undefined);
    else if (value === GITHUB_MORE) github?.onConnect();
    else if (repoRows.has(value)) {
      const folder = githubFolder(repoRows.get(value)!.fullName);
      if (folder !== current) onPick(folder);
    } else if (value && value !== current && (shown.has(value) || value === typedPath)) onPick(value);
  };
  const row = (value: string) => {
    // The GitHub group's heading sits over its first row (composerLocation.css `data-section`).
    const section = value === githubRows[0] && value !== GITHUB_ADD ? t("cloudRepository.github") : undefined;
    if (value === GITHUB_ADD || value === GITHUB_MORE)
      return (
        <span className="acpmux-location-action acpmux-location-row" data-github="" data-section={section}>
          <span className="acpmux-location-action-icon" aria-hidden="true">
            {value === GITHUB_ADD ? <GitHubMark /> : <ActionIcon action={ACTION + "browse"} />}
          </span>
          <span className="acpmux-menu-label">
            {t(value === GITHUB_ADD ? "composer.githubAddRepos" : "composer.githubChooseMore")}
          </span>
        </span>
      );
    const githubRepo = repoRows.get(value);
    if (githubRepo)
      return (
        <span
          className="acpmux-location-row"
          data-github=""
          data-section={section}
          data-current={githubRepo.fullName === currentRepo ? "" : undefined}
        >
          <span className="acpmux-location-action-icon" aria-hidden="true">
            <GitHubMark />
          </span>
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{githubRepo.fullName}</span>
          </span>
          {githubRepo.private && (
            <span className="acpmux-location-lock">
              <LockIcon />
              <span className="acpmux-env-status-text">{t("composer.githubPrivate")}</span>
            </span>
          )}
          <span className="acpmux-location-check" aria-hidden="true">
            {githubRepo.fullName === currentRepo && <CheckIcon />}
          </span>
        </span>
      );
    const action = actions.find((candidate) => candidate.value === value);
    if (action)
      return (
        <span
          className="acpmux-location-action"
          data-first={action === actions[0] ? "" : undefined}
          data-choose={action.value === ACTION + "browse" ? "" : undefined}
        >
          <span className="acpmux-location-action-icon" aria-hidden="true">
            <ActionIcon action={action.value} />
          </span>
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
        // tooltip-allow: the fixed footer column may truncate a long folder name.
        title={current}
        {...press}
      >
        {face}
      </button>
      <Popover
        id={press["aria-controls"]}
        open={open}
        onOpenChange={(next, details) => {
          // Escape on the install card goes back to the list, not out of the menu.
          if (!next && details?.escape && cardShown) {
            refocusField.current = true;
            setGitHubCard(false);
            return;
          }
          if (!next && details?.escape) {
            escaped.current = true;
            close();
          } else {
            setOpen(next);
            // Every close ends Add another folder…'s mode, an outside click as much as Escape (cmux#34408).
            if (!next) {
              setQuery("");
              setExpanded(new Set());
              setAddingExtra(false);
            }
          }
        }}
        anchor={open ? anchor : null}
        label={label}
        className={
          "acpmux-menu acpmux-location-menu acpmux-folder-popover" +
          (highlightAuto && query.trim() === "" ? " acpmux-folder-highlight-auto" : "")
        }
        side={side}
        flip={flip}
        finalFocus={false}
      >
        {cardShown ? (
          <GitHubInstallCard
            waiting={github?.state.waiting === true}
            {...(github?.state.connectError ? { error: github.state.connectError } : {})}
            onInstall={() => github?.onConnect()}
            onBack={() => {
              refocusField.current = true;
              setGitHubCard(false);
            }}
          />
        ) : (
          <>
            <Combobox
              // A fresh field for Add another folder…'s pick.
              key={addingExtra ? "extra" : "folder"}
              inputRef={fieldMounted}
              suggestions={suggestions}
              pinnedSuggestions={pinned}
              pinnedPlacement="bottom"
              cancelOnBlur={false}
              onQuery={(next) => {
                setQuery(next);
                // Words that no longer hold the ones GitHub was asked for: back to the whole first page.
                const asked = github?.state.query;
                if (asked && !next.trim().toLowerCase().includes(asked.toLowerCase())) github.onSearch(null);
              }}
              onSubmit={submit}
              onCancel={close}
              onHighlight={(value, by) => {
                highlighted.current = value;
                setHighlightAuto(by === "none");
              }}
              // Tab completes a folder's path into the field, never an action's or a GitHub row's.
              onCommand={(event) => {
                if (event.key === "Escape") escaped.current = true;
                if (arrow(event.key)) event.preventDefault();
                if (event.key === "Tab" && highlighted.current?.startsWith("\u0000")) event.preventDefault();
              }}
              label={t(addingExtra ? "composer.addFolderSearch" : "composer.folderSearch")}
              placeholder={t(addingExtra ? "composer.addFolderSearch" : "composer.folderSearch")}
              inputClassName="acpmux-location-search"
              listClassName="acpmux-location-folders"
              itemClassName="acpmux-menu-item"
              renderItem={row}
              autoHighlight
              inline
              // Thousands of projects (Leo 2026-11-04): only the rows in view mount.
              virtualRows={{ estimate: 28 }}
            />
            {shown.size === 0 && !typedPath && githubRows.length === 0 && (
              <div className="acpmux-location-empty">{t(typed ? "composer.folderNone" : "composer.folderNoneYet")}</div>
            )}
            {github?.state.error !== undefined && githubStatus === "ready" && (
              <div className="acpmux-location-empty acpmux-github-error" role="alert">
                <span className="acpmux-github-error-text">{github.state.error}</span>
                <Button variant="ghost" size="sm" onClick={() => github.onRetry()}>
                  {t("project.retry")}
                </Button>
              </div>
            )}
            {extra && !addingExtra && <ExtraFolderList folders={extra.folders} onRemove={extra.onRemove} />}
            {note && <p className="acpmux-location-note">{note}</p>}
          </>
        )}
      </Popover>
    </span>
  );
}

/// An action row's value: never a path.
const ACTION = "\u0000action:";
const ACTION_EXTRA = ACTION + "extra";
/// The GitHub part's rows: never a path either.
const GITHUB_ADD = "\u0000github:add";
const GITHUB_MORE = "\u0000github:more";
const GITHUB_REPO = "\u0000github:repo:";

/// An action's glyph in the folders' icon column: + adds, a folder with + adds one more, the branch
/// is a worktree, × is no folder.
function ActionIcon({ action }: { action: string }) {
  if (action === ACTION + "worktree") return <BranchIcon />;
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
      {action === ACTION + "none" ? (
        <path d="m4.5 4.5 7 7M11.5 4.5l-7 7" />
      ) : action === ACTION_EXTRA ? (
        <path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2.6l1.4 1.5h5A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5zM8 7v4M6 9h4" />
      ) : (
        <path d="M8 3v10M3 8h10" />
      )}
    </svg>
  );
}

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
      <path d="m6 3.5 4.5 4.5L6 12.5" />
    </svg>
  );
}
