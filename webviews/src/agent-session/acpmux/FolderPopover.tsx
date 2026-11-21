import React, { useMemo, useRef, useState } from "react";
import { useLocationShortcut } from "./composerControls";
import { Combobox } from "../../ui/Combobox";
import { Popover } from "../../ui/Popover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import type { BrowseRequest } from "./AddProjectPanel";
import type { BrowseResult } from "./addProjectPanelModel";
import { ExtraFolderList } from "./ExtraFolderList";
import type { ExtraFolderRows } from "./extraFolders";
import { GitHubMark, LockIcon } from "./GitHubIcons";
import { githubFolder, githubFolderRepo, matchingRepos, type GitHubPicker } from "./githubRepos";
import { translate as t } from "./i18n";
import { FOLDER_MENU_LIST_CAP, folderMenuShortest, useLocationOpener, useLocationPopover } from "./locationPopover";
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
/// newest worktree; its chevron (with the count of its other worktrees, when it has any) opens them
/// under it, newest first, then New worktree, which makes one of that repository (→ opens, ← or the
/// chevron closes). The current folder is checked. Only three actions are fixed under the scrolling
/// folders, each with its glyph in the folders' icon column (cmux#48299: "why do we have so many
/// buttons stuck to the bottom of this menu?"): Add folder…, the GitHub row only when a click on it
/// does something, and No folder last, where the host offers them. A folder the new chat should also
/// see is added from its own row (its + button, or Shift-Return), not from a second Add folder row.
/// The empty line (no folders yet, or none match the words) sits in the list's place, over the
/// actions (Combobox `listEnd`); only the extra folders a chat already has (ExtraFolderList) are
/// listed under them.
/// A folder is the one thing the menu picks (Leo, 2026-11-06: "what even is the deal with add
/// project? ... why not just add fodler? what's special about project?"): Add folder… is the host's
/// folder panel, and a folder picked there is listed with the others from then on. The shared
/// Combobox keeps the keyboard in the field:
/// typing filters by repository, branch and path, and lists a worktree on its own when the words
/// name it; ↑/↓ move through the rows and the actions; Return picks; Escape closes back to the
/// strip. A typed absolute or `~/` path is offered as typed.
/// `github` (a new chat that can run on Cloud, githubRepos.ts) adds the person's GitHub repositories
/// to the list: a GitHub group, filtered by the same search, whose pick is the folder
/// `github:owner/name`, over the folders for a chat set to Cloud (`githubFirst`), else under them.
/// The GitHub row is a fixed action under Add folder…: Choose more repositories… (the installation's
/// page on GitHub) once connected, so a connected team always sees it; Retry, its second line the
/// error, when the repositories' list failed to load (a click reads it again, the menu still open).
/// GitHub is optional: while the cmux GitHub App is not installed, or the person is signed out, the
/// row is Connect to GitHub (none on a Cloud service with no GitHub App, none while the check did
/// not answer, none before the first status read answers), and one click connects in place: the host
/// opens the install page, or sign-in when signed out, the menu stays open and lists the repositories
/// once the status says ready. The row is its title alone; only a refusal (a click tries again) adds
/// a second line. GitHub's own page is the one wait: no Waiting for GitHub… under the row. It never
/// picks a folder. With the repositories listed first, the folders after them are headed This Mac,
/// so they never read as part of the GitHub group.
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
  extra,
  github,
  githubFirst = false,
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
  /// New worktree of a repository, from its row's chevron: `cwd` is its main checkout (else its row's folder).
  onNewWorktree?(cwd: string): void;
  /// No folder (Leo 2026-10-18): the chat starts in no folder of
  /// the user's (its private one). Checked while `noProject`.
  onNoProject?(): void;
  noProject?: boolean;
  /// The new chat's extra folders (extraFolders.ts): a folder row's + (or Shift-Return) adds it as one
  /// more folder the chat sees beside its own, and the ones added are listed under the actions.
  extra?: ExtraFolderRows;
  /// A new Cloud chat's GitHub repositories (githubRepos.ts); none for any other chat.
  github?: GitHubPicker;
  /// The repositories list above the folders (a chat set to Cloud); under them otherwise.
  githubFirst?: boolean;
}) {
  const [query, setQuery] = useState("");
  // The repositories whose worktrees are open under their row, by group key.
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const highlighted = useRef<string | undefined>(undefined);
  const [highlightAuto, setHighlightAuto] = useState(true);
  const trigger = useRef<HTMLButtonElement>(null);
  // Escape (not a blur) closes back to the strip's control.
  const escaped = useRef(false);
  // Its side is chosen for its own taller list and its own actions, not the shared location list's.
  const {
    control,
    anchor,
    open,
    setOpen: setPopoverOpen,
    side,
    flip,
  } = useLocationPopover({ listCap: FOLDER_MENU_LIST_CAP });
  const setOpen = (next: boolean) => {
    if (next) {
      setHighlightAuto(true);
      // Each open reads whether GitHub is connected, and its repositories once it is.
      if (!open) github?.onOpen();
    }
    // The side fits the rows and actions the menu has now (they are counted below, before any press),
    // the GitHub row its status may still add, and the chat's extra folders listed under the actions.
    const below = pinned.length + (github && !githubAction ? 1 : 0) + (extra?.folders.length ?? 0);
    setPopoverOpen(next, folderMenuShortest(suggestions.length - pinned.length, below));
  };
  const press = usePopoverTrigger(open, (next) => {
    setOpen(next);
    if (!next) {
      setQuery("");
      setExpanded(new Set());
    }
  });
  useLocationOpener(menu, () => setOpen(true));
  const shortcut = useLocationShortcut(menu);
  const extraFolders = extra?.folders;
  // The filesystem root is no project, so it is never listed: a chat someone started there (a shell
  // at `/`) put a row among the folders that named no folder. Typing `/` still offers it as a path.
  const offered = useMemo(() => folders.filter((folder) => !/^\/+$/.test(folder.id)), [folders]);
  const groups = useMemo(() => groupByRepo(offered, current), [offered, current]);
  // Repositories that share a name (two clones both called "cmux") are told apart by their path.
  const suffixes = useMemo(
    () => projectSuffixes(groups.map((group) => ({ cwd: group.lead.id, label: group.name }))),
    [groups],
  );
  const rows = useMemo(() => shownRepoRows(groups, query, expanded), [groups, query, expanded]);
  // A repository's chevron also offers New worktree, so every git repository has one, not only those
  // with worktrees already. Never while words are typed (the rows are search results then).
  // A folder the host named no repository for still makes one when it is the chat's own folder, as
  // before: the host says so if it is not a git checkout.
  const makesWorktree = (group: (typeof groups)[number]) =>
    onNewWorktree !== undefined && (folderRepo(group.lead) !== undefined || group.lead.id === current);
  const opensUnder = (group: (typeof groups)[number]) => group.members.length > 1 || makesWorktree(group);
  // Each shown folder's row: a repository's (`group` only) or a worktree's under it, and the New
  // worktree row (by its value) that ends an open repository's worktrees, with the folder it is made from.
  const { shown, newWorktrees, listed } = useMemo(() => {
    const byValue = new Map<string, { group: (typeof groups)[number]; worktree?: FolderChoice }>();
    const made = new Map<string, { group: (typeof groups)[number]; from: string }>();
    const order: string[] = [];
    for (const { group, worktrees } of rows) {
      byValue.set(group.lead.id, { group });
      order.push(group.lead.id);
      for (const worktree of worktrees) {
        byValue.set(worktree.id, { group, worktree });
        order.push(worktree.id);
      }
      const makes = onNewWorktree !== undefined && (folderRepo(group.lead) !== undefined || group.lead.id === current);
      if (!query.trim() && expanded.has(group.key) && makes) {
        const value = NEW_WORKTREE + group.key;
        made.set(value, { group, from: (group.members.find(isMainCheckout) ?? group.lead).id });
        order.push(value);
      }
    }
    return { shown: byValue, newWorktrees: made, listed: order };
  }, [rows, onNewWorktree, query, expanded, current]);
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
  const githubStatus = github?.state.status?.state;
  const githubReady = githubStatus === "ready" && github?.state.error === undefined;
  const githubRepos = github?.state.repos;
  const repos = useMemo(
    () => (githubReady && githubRepos ? matchingRepos(githubRepos, typed) : []),
    [githubReady, githubRepos, typed],
  );
  // The GitHub row is pinned with the actions under the list: the folder list scrolls (thousands of
  // projects), and a row at its end would sit below the fold where nobody finds it. Connected: Choose
  // more repositories…, or Retry when the repositories' list failed. Connect to GitHub only where a
  // click can connect: not connected, or signed out (the click signs in first). Never while the check
  // did not answer (a connected team's check can fail), nor on a Cloud service with no GitHub App (#46018).
  const githubAction = github
    ? githubReady
      ? GITHUB_MORE
      : githubStatus === "ready"
        ? GITHUB_RETRY
        : githubStatus === "not_connected" ||
            (githubStatus === "unavailable" && github.state.status?.reason === "signed_out")
          ? GITHUB_ADD
          : undefined
    : undefined;
  const githubRows = repos.map((repo) => GITHUB_REPO + repo.fullName);
  const repoRows = useMemo(() => new Map(repos.map((repo) => [GITHUB_REPO + repo.fullName, repo])), [repos]);
  const currentRepo = githubFolderRepo(current);
  // Actions stay under the folders; the arrows reach them after the last folder. Only the ones that
  // choose where the chat starts: Add folder… and No folder (cmux#48299). New worktree is a
  // repository's (its chevron), and a folder the chat also sees is added from its row.
  const actions: {
    value: string;
    text: string;
    run(): Promise<BrowseResult> | BrowseResult | void;
  }[] = [
    ...(onBrowse ? [{ value: ACTION + "browse", text: t("composer.addFolder"), run: onBrowse }] : []),
    ...(onNoProject ? [{ value: ACTION + "none", text: t("project.noFolder"), run: onNoProject }] : []),
  ];
  // A folder row's + : the chat also sees it. Not the chat's own folder, nor one already added.
  const addsExtra = (id: string) => extra !== undefined && id !== current && !extraFolders?.includes(id);
  // The GitHub row sits right under Add folder….
  const actionValues = actions.map((action) => action.value);
  const afterBrowse = actionValues[0] === ACTION + "browse" ? 1 : 0;
  const pinned = githubAction
    ? [...actionValues.slice(0, afterBrowse), githubAction, ...actionValues.slice(afterBrowse)]
    : actionValues;
  // A Cloud chat lists the repositories first (the machine clones one); any other lists the folders first.
  const suggestions = [
    ...pinned,
    ...(githubFirst ? githubRows : []),
    ...listed,
    ...(typedPath ? [typedPath] : []),
    ...(githubFirst ? [] : githubRows),
  ];
  // A worktree or subfolder leading its row is named by its branch or path; the main checkout needs none.
  const leadSuffix = (folder: FolderChoice) =>
    folderRepo(folder) && !isMainCheckout(folder) ? worktreeName(folder) : suffixes.get(folder.id);
  // The menu is as wide as its fullest listed row needs (composerLocation.css `.acpmux-folder-fit`).
  // The list mounts only the rows in view and places them itself, so the rows give the popup no
  // width: the longest rows' words are listed once more, unseen, and the browser measures those.
  // Only while open: a closed menu measures nothing, whatever re-renders its composer.
  const fit = widestLines(
    (open ? suggestions.slice(pinned.length) : []).map((value): FitLine => {
      const place = shown.get(value);
      if (newWorktrees.has(value)) return { text: t("worktree.new"), kind: "worktree" };
      if (!place) {
        const repo = repoRows.get(value);
        return repo
          ? { text: repo.fullName, kind: repo.private ? "lock" : "row" }
          : { text: t("project.usePath", { path: value }), kind: "row" };
      }
      if (place.worktree) return { text: worktreeName(place.worktree), kind: "worktree" };
      const suffix = leadSuffix(place.group.lead);
      const others = place.group.members.length - 1;
      const name = suffix ? `${place.group.name} · ${suffix}` : place.group.name;
      return opensUnder(place.group) && !typed
        ? { text: others > 0 ? `${name} ${others}` : name, kind: "count" }
        : { text: name, kind: "row" };
    }),
  );
  const close = () => {
    setOpen(false);
    setQuery("");
    setExpanded(new Set());
    if (escaped.current) trigger.current?.focus();
    escaped.current = false;
  };
  const submit = (value: string) => {
    // Connect to GitHub connects from the row in one click (the host opens the install page, or
    // sign-in), the menu still open; a click while it waits opens the page again.
    if (value === GITHUB_ADD) {
      github?.onConnect();
      return;
    }
    // Retry reads the repositories again, the menu still open; they are listed once they load.
    if (value === GITHUB_RETRY) {
      github?.onRetry();
      return;
    }
    // Return on words no loaded repository matches: ask GitHub for them (the loaded page may be
    // only the first of the person's repositories). The field's words arrive as the value: with
    // words typed, the Combobox never submits a pinned row it highlighted by itself.
    if (githubReady && typed && !typedPath && repos.length === 0 && github?.state.truncated && value === query) {
      github.onSearch(typed);
      return;
    }
    const action = actions.find((candidate) => candidate.value === value);
    const worktreeOf = newWorktrees.get(value);
    close();
    if (worktreeOf) onNewWorktree?.(worktreeOf.from);
    else if (action)
      void Promise.resolve()
        .then(() => action.run())
        .catch(() => undefined);
    else if (value === GITHUB_MORE) github?.onConnect();
    else if (repoRows.has(value)) {
      const folder = githubFolder(repoRows.get(value)!.fullName);
      if (folder !== current) onPick(folder);
    } else if (value && value !== current && (shown.has(value) || value === typedPath)) onPick(value);
  };
  // Under the repositories (a Cloud chat) the folders are headed This Mac, apart from the GitHub group.
  const firstFolder = githubFirst && githubRows.length > 0 ? (listed[0] ?? typedPath) : undefined;
  // The GitHub group's heading sits over its first row, and This Mac over the first folder after
  // the repositories (composerLocation.css `data-section`, drawn in the row's margin).
  const sectionOf = (value: string) =>
    value === githubRows[0] ? t("cloudRepository.github") : value === firstFolder ? t("composer.thisMac") : undefined;
  const row = (value: string) => {
    const section = sectionOf(value);
    if (value === GITHUB_ADD) {
      const reason = githubStatus === "unavailable" ? github?.state.status?.reason : undefined;
      // The title alone: GitHub's own page is the one place the person waits, so the row adds no
      // Waiting for GitHub… nor a reason under it. Only a click the host refused says why (#46018).
      const detail = github?.state.connectError;
      return (
        <span className="acpmux-location-action acpmux-location-row" data-github="" data-github-unavailable={reason}>
          <span className="acpmux-location-action-icon" aria-hidden="true">
            <GitHubMark />
          </span>
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{t("composer.githubConnect")}</span>
            {detail && <span className="acpmux-menu-description">{detail}</span>}
          </span>
        </span>
      );
    }
    if (value === GITHUB_RETRY)
      return (
        <span className="acpmux-location-action acpmux-location-row" data-github="" data-github-retry="">
          <span className="acpmux-location-action-icon" aria-hidden="true">
            <GitHubMark />
          </span>
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{t("project.retry")}</span>
            <span className="acpmux-menu-description">{github?.state.error}</span>
          </span>
        </span>
      );
    if (value === GITHUB_MORE)
      return (
        <span className="acpmux-location-action acpmux-location-row" data-github="">
          <span className="acpmux-location-action-icon" aria-hidden="true">
            <ActionIcon action={ACTION + "browse"} />
          </span>
          <span className="acpmux-menu-label">{t("composer.githubChooseMore")}</span>
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
    if (newWorktrees.has(value))
      return (
        <span className="acpmux-location-row" data-worktree="" data-new-worktree="">
          <span className="acpmux-location-branch-icon" aria-hidden="true">
            <ActionIcon action={ACTION + "browse"} />
          </span>
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{t("worktree.new")}</span>
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
        <span className="acpmux-location-row" data-section={section}>
          <span className="acpmux-menu-label">{t("project.usePath", { path: value })}</span>
          {addsExtra(value) && <AlsoSee name={value} onAdd={() => extra?.onAdd(value)} />}
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
          {addsExtra(worktree.id) && <AlsoSee name={worktreeName(worktree)} onAdd={() => extra?.onAdd(worktree.id)} />}
          <span className="acpmux-location-check" aria-hidden="true">
            {worktree.id === current && <CheckIcon />}
          </span>
        </span>
      );
    const folder = group.lead;
    const repo = folderRepo(folder);
    const suffix = leadSuffix(folder);
    const others = group.members.length - 1;
    const open = expanded.has(group.key);
    return (
      <span
        className="acpmux-location-row"
        // tooltip-allow: the row shows the folder's name; the tooltip is its full path
        title={folder.id}
        data-section={section}
        data-current={folder.id === current ? "" : undefined}
        data-expanded={opensUnder(group) && !typed ? String(open) : undefined}
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
        {addsExtra(folder.id) && <AlsoSee name={group.name} onAdd={() => extra?.onAdd(folder.id)} />}
        {opensUnder(group) && !typed && (
          // The chevron (and the count, when there are other worktrees) opens or closes the
          // repository's worktrees and its New worktree; a press here never picks the row (the
          // arrows do the same from the field).
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
            {others > 0 && (
              <>
                <BranchIcon />
                {others}
              </>
            )}
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
    if (!place || !opensUnder(place.group)) return false;
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
        // tooltip-allow: the fixed footer column may truncate a long folder name; with none picked the
        // tooltip names the control, so its key (data-tooltip-shortcut) still shows.
        title={current || label}
        data-tooltip-shortcut={shortcut}
        {...press}
      >
        {face}
      </button>
      <Popover
        id={press["aria-controls"]}
        open={open}
        onOpenChange={(next, details) => {
          if (!next && details?.escape) {
            escaped.current = true;
            close();
          } else {
            setOpen(next);
            if (!next) {
              setQuery("");
              setExpanded(new Set());
            }
          }
        }}
        anchor={open ? anchor : null}
        label={label}
        className={
          "acpmux-menu acpmux-location-menu acpmux-folder-popover" +
          // Short of room the list keeps up to three of its rows over the actions (composerLocation.css).
          ` acpmux-folder-rows-${Math.min(3, suggestions.length - pinned.length)}` +
          (highlightAuto && query.trim() === "" ? " acpmux-folder-highlight-auto" : "")
        }
        side={side}
        flip={flip}
        finalFocus={false}
      >
        <span className="acpmux-folder-fit" aria-hidden="true">
          {fit.map((line) => (
            <span key={line.kind + line.text} data-text={line.text} data-kind={line.kind} />
          ))}
        </span>
        <Combobox
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
            // Shift-Return on a folder: the chat also sees it (its row's +), the menu still open.
            const folder = highlighted.current;
            if (extra && event.key === "Enter" && event.shiftKey && folder && (shown.has(folder) || folder === typedPath)) {
              // Never a pick: on the chat's own folder or one already added it does nothing.
              event.preventDefault();
              event.preventBaseUIHandler?.();
              if (addsExtra(folder)) extra.onAdd(folder);
            }
          }}
          label={t("composer.folderSearch")}
          placeholder={t("composer.folderSearch")}
          inputClassName="acpmux-location-search"
          listClassName="acpmux-location-folders"
          itemClassName="acpmux-menu-item"
          renderItem={row}
          autoHighlight
          inline
          // Thousands of projects (Leo 2026-11-04): only the rows in view mount.
          // A heading changes a row's margin, not its box: the row is measured again when it changes.
          virtualRows={{ estimate: 28, sizeKey: (value) => sectionOf(value) ?? "" }}
          // The empty line sits in the list's place, over the actions.
          listEnd={
            shown.size === 0 && !typedPath && githubRows.length === 0 ? (
              <div className="acpmux-location-empty">{t(typed ? "composer.folderNone" : "composer.folderNoneYet")}</div>
            ) : undefined
          }
        />
        {extra && <ExtraFolderList folders={extra.folders} onRemove={extra.onRemove} />}
      </Popover>
    </span>
  );
}

/// One listed row's words and what its row draws beside them (a worktree count, a worktree's
/// indent, a private repository's lock glyph), for the menu's width.
export type FitLine = { text: string; kind: "row" | "count" | "worktree" | "lock" };

/// The few lines that can be the widest: the longest by their letters, the room beside them counted
/// in letters too. Thousands of folders stay a handful of measured lines.
export function widestLines(lines: readonly FitLine[], keep = 6): FitLine[] {
  const reach = (line: FitLine) => line.text.length + FIT_KIND_LETTERS[line.kind];
  // One pass, the kept few in order: no sort of every folder on each render.
  const widest: FitLine[] = [];
  for (const line of lines) {
    if (widest.length === keep && reach(line) <= reach(widest[keep - 1]!)) continue;
    if (widest.some((kept) => kept.kind === line.kind && kept.text === line.text)) continue;
    const at = widest.findIndex((kept) => reach(kept) < reach(line));
    widest.splice(at === -1 ? widest.length : at, 0, line);
    if (widest.length > keep) widest.pop();
  }
  return widest;
}

/// About how many letters wide each kind's extra room is (composerLocation.css gives the real widths).
const FIT_KIND_LETTERS: Record<FitLine["kind"], number> = { row: 0, count: 5, worktree: 3, lock: 3 };

/// An action row's value: never a path.
const ACTION = "\u0000action:";
/// A repository's New worktree row, by its group key: never a path either.
const NEW_WORKTREE = "\u0000worktree:new:";
/// The GitHub part's rows: never a path either.
const GITHUB_ADD = "\u0000github:add";
const GITHUB_MORE = "\u0000github:more";
const GITHUB_RETRY = "\u0000github:retry";
const GITHUB_REPO = "\u0000github:repo:";

/// A folder row's + : the new chat also sees that folder, beside its own (extraFolders.ts). A press
/// never picks the row; it shows while the row is hovered or highlighted (composerLocation.css).
function AlsoSee({ name, onAdd }: { name: string; onAdd(): void }) {
  const label = t("composer.alsoSeeFolder", { name });
  return (
    // Out of the option's accessible name: Shift-Return is its keyboard way, the tooltip names it.
    <span
      className="acpmux-location-also"
      aria-hidden="true"
      // tooltip-allow: an icon-only control names what it does
      title={label}
      data-label={label}
      data-also-see=""
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
        onAdd();
      }}
    >
      <ActionIcon action={ACTION + "extra"} />
    </span>
  );
}

/// An action's glyph in the folders' icon column: + adds, a folder with + adds one more, × is no folder.
function ActionIcon({ action }: { action: string }) {
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
      ) : action === ACTION + "extra" ? (
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
