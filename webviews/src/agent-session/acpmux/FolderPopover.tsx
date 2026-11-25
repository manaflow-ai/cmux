import React, { useEffect, useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { Popover } from "../../ui/Popover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import type { BrowseRequest, BrowseResult } from "./browseProject";
import { useLocationShortcut } from "./composerControls";
import { MenuFolderIcon, PlusIcon } from "./ComposerPickers";
import { ExtraFolderList } from "./ExtraFolderList";
import type { ExtraFolderRows } from "./extraFolders";
import { LockIcon, GitHubGlyph } from "./GitHubIcons";
import { folderUsedAt, mergeByRecentUse, readAddedRepos, rememberAddedRepo, type AddedRepo } from "./addedRepos";
import { githubFolder, githubFolderRepo } from "./githubRepos";
import { useT } from "./i18n";
import { FOLDER_MENU_LIST_CAP, folderMenuShortest, useLocationOpener, useLocationPopover } from "./locationPopover";
import { ProjectBadge } from "./ProjectBadge";
import { projectSuffixes } from "./projectSuffix";
import {
  folderRepo,
  groupByRepo,
  isMainCheckout,
  shownRepoRows,
  worktreeName,
  type ProjectRepo,
  belowCheckout,
} from "./projectRepos";
import { SourcePicker, type SourcePickerOptions } from "./SourcePicker";
import { matchesSourceQuery } from "./sourcePickerModel";

const NO_FOLDERS: FolderChoice[] = [];
const NO_REPOS: readonly AddedRepo[] = [];
/// A folder named by a bare UUID (a chat's or a workspace's private folder): never a project to pick (cmux#53226).
const UUID_FOLDER = /\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/*$/i;

/// A folder the popover offers: its path (`id`), name and, when known, its repository.
export type FolderChoice = { id: string; label: string; repo?: ProjectRepo };

/// The composer folder chip. Projects scroll above the actions, and Add project opens the source picker.
/// One list, most recently used first (cmux#53226): the folders, and among them the GitHub repositories the
/// person added as a project (addedRepos.ts), never every repository on the account and never under a
/// section of their own. A folder that is a clone of a GitHub repository (its `origin`) is that repository's
/// one row, with the GitHub glyph; a repository is listed apart only while no folder here is a clone of it.
/// Nothing is read from GitHub until Add project opens. A Cloud machine's folders keep their machine's heading.
export function FolderPopover({
  label,
  menu,
  face,
  folders,
  current,
  currentPeer,
  onPick,
  onBrowse,
  onNewWorktree,
  onNoProject,
  newProject = false,
  extra,
  sources,
  cloningRepository,
  pendingRepository,
}: {
  label: string;
  /// The name automation opens it by (`openPicker`).
  menu: string;
  /// The strip control's face (icon, name, chevron).
  face: React.ReactNode;
  folders: FolderChoice[];
  current?: string;
  currentPeer?: string;
  onPick(cwd: string): void;
  /// The host's folder panel: Add folder….
  onBrowse?(request?: BrowseRequest): Promise<BrowseResult> | BrowseResult | void;
  /// New Worktree of the current folder.
  onNewWorktree?(): void;
  /// Clear the selected folder so the chat starts in its private folder.
  onNoProject?(): void;
  /// A new empty project is the choice: it has no folder yet, but No folder is not what was picked.
  newProject?: boolean;
  /// The extra folders the new chat can see beside its project.
  extra?: ExtraFolderRows;
  /// New-chat project sources. Other consumers open directly on the folder list.
  sources?: SourcePickerOptions;
  cloningRepository?: string;
  /// A GitHub repository picked with This Mac picked, not checked out yet: Return checks it out (cmux#53226).
  pendingRepository?: string;
}) {
  const t = useT();
  const [query, setQuery] = useState("");
  const typed = query.trim();
  const [sourcesOpen, setSourcesOpen] = useState(false);
  const [cloning, setCloning] = useState<string>();
  const cloningName = cloning ?? cloningRepository;
  const cloudFolders = sources?.cloudFolders;
  const cloud = cloudFolders !== undefined;
  const github = sources?.github;
  // The repository the person wanted when Connect or Choose more repositories… started came back listed (the app
  // finished GitHub's return): it becomes the chat's folder with no second click (Leo 2026-11-25).
  const returned = github?.state.returned;
  const takeReturned = github?.onTakeReturned;
  const returnedPrivate = github?.state.repos?.find((item) => item.fullName === returned)?.private ?? false;
  useEffect(() => {
    if (!returned) return;
    // Taken first: the store forgets it, so this runs once per return.
    takeReturned?.();
    rememberAddedRepo({ fullName: returned, private: returnedPrivate });
    if (githubFolder(returned) !== current) onPick(githubFolder(returned));
  }, [returned, takeReturned, returnedPrivate, current, onPick]);
  // The repositories whose worktrees are open under their row, by group key.
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const [searchCollapsed, setSearchCollapsed] = useState<ReadonlySet<string>>(() => new Set());
  // A click on a worktree count holds the menu's height while the pointer stays in it, so the rows under the
  // pointer stay put (the menu fits its rows and is pinned at the chip: opening or closing worktrees would move
  // its top edge and every row with it). Leaving the menu, or closing it, lets it fit its rows again.
  const [heldHeight, setHeldHeight] = useState<number>();
  const highlighted = useRef<string | undefined>(undefined);
  const [highlightBy, setHighlightBy] = useState<"keyboard" | "pointer" | "none">("none");
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
  // The filesystem root is no project. Typing / still offers it as a path. A closed menu offers none: the folders
  // change with every chat that works in another one, and grouping thousands of them by repository on each change
  // of a menu nobody opened cost each page about 7 ms a second at 10K chats (bench/session-scale-typing.bench.ts).
  const offered = useMemo(
    () => (open ? folders.filter((folder) => !/^\/+$/.test(folder.id) && !UUID_FOLDER.test(folder.id)) : NO_FOLDERS),
    [open, folders],
  );
  const groups = useMemo(() => groupByRepo(offered, current, "main"), [offered, current]);
  const currentGroup = useMemo(
    () => groups.find((group) => group.members.some((member) => member.id === current)),
    [groups, current],
  );
  const worktreeActionGroup = !cloud && onNewWorktree ? currentGroup?.key : undefined;
  // Repositories that share a name (two clones both called "cmux") are told apart by their path.
  const suffixes = useMemo(
    () => projectSuffixes(groups.map((group) => ({ cwd: group.lead.id, label: group.name }))),
    [groups],
  );
  const rows = useMemo(() => shownRepoRows(groups, query, expanded), [groups, query, expanded]);
  // Each shown folder's row: a repository's (`group` only) or a worktree's under it.
  const shown = useMemo(() => {
    const byValue = new Map<
      string,
      { group: (typeof groups)[number]; worktree?: FolderChoice; disclosure?: { count: number; open: boolean } }
    >();
    for (const { group, worktrees } of rows) {
      const count = typed ? worktrees.length : group.members.length - 1;
      const open = typed ? count > 0 && !searchCollapsed.has(group.key) : expanded.has(group.key);
      const hasAction = !typed && group.key === worktreeActionGroup;
      byValue.set(group.lead.id, { group, disclosure: count > 0 || hasAction ? { count, open } : undefined });
      if (hasAction && open) {
        byValue.set(ACTION_WORKTREE, { group });
      }
      if (open) for (const worktree of worktrees) byValue.set(worktree.id, { group, worktree });
    }
    return byValue;
  }, [expanded, rows, searchCollapsed, typed, worktreeActionGroup]);
  const disclosureLabel = ({ count, open }: { count: number; open: boolean }) =>
    open ? t("project.hideWorktrees") : count ? t("project.showWorktrees", { n: count }) : t("project.newWorktree");
  const toggle = (key: string, open: boolean) => {
    const setKeys = typed ? setSearchCollapsed : setExpanded;
    const include = typed ? !open : open;
    setKeys((before) => {
      if (before.has(key) === include) return before;
      const next = new Set(before);
      if (include) next.add(key);
      else next.delete(key);
      return next;
    });
  };
  const typedPath = !cloud && /^(?:\/|~\/)/.test(typed) && !shown.has(typed) ? typed : undefined;
  // The GitHub repositories added as projects, read as the menu opens.
  const [added, setAdded] = useState<readonly AddedRepo[]>(NO_REPOS);
  // The repositories a listed folder is a clone of: that folder is their row. Listing the account's
  // repositories beside the folders drew this Mac's clone of one twice, once by folder, once by name.
  const cloned = useMemo(
    () => new Set(offered.flatMap((folder) => (folder.repo?.github ? [folder.repo.github.toLowerCase()] : []))),
    [offered],
  );
  const githubRows = useMemo(
    () =>
      new Map(
        added
          .filter((repo) => !cloned.has(repo.fullName.toLowerCase()) && matchesSourceQuery(repo.fullName, typed))
          .map((repo) => [GITHUB_REPO + repo.fullName, repo]),
      ),
    [added, cloned, typed],
  );
  const cloudRows = useMemo(
    () =>
      new Map(
        (cloudFolders ?? [])
          .filter((folder) => matchesSourceQuery(`${folder.label} ${folder.id} ${folder.machine}`, typed))
          .map((folder) => [`\u0000cloud:${JSON.stringify([folder.peer, folder.id])}`, folder]),
      ),
    [cloudFolders, typed],
  );
  const sections = useMemo(() => {
    const headings = new Map<string, string>();
    let previousPeer: string | undefined;
    for (const [value, folder] of cloudRows) {
      if (folder.peer !== previousPeer) headings.set(value, folder.machine);
      previousPeer = folder.peer;
    }
    return headings;
  }, [cloudRows]);
  // Actions stay under the folders; the arrows reach them after the last folder.
  // The two actions under the list: Add project… and No folder (always there; checked while nothing is
  // picked and no new project is the choice).
  const pinned = sources ? [ACTION_ADD, ...(onNoProject ? [ACTION_NONE] : [])] : onBrowse ? [ACTION_BROWSE] : [];
  const listValues = useMemo(
    () => orderedRows({ cloud, cloudRows, githubRows, shown, typed, typedPath }),
    [cloud, cloudRows, githubRows, shown, typed, typedPath],
  );
  // A heading under other rows opens with a hairline; the list's first row has the field's line over it.
  const dividerOf = (value: string) => (sections.has(value) && value !== listValues[0] ? "" : undefined);
  const suggestions = [...pinned, ...listValues];
  const actionCount = pinned.length + (!cloud ? (extra?.folders.length ?? 0) : 0);
  // A worktree or subfolder leading its row is named by its branch or path; the main checkout needs none.
  const leadSuffix = (folder: FolderChoice) =>
    folderRepo(folder) && !isMainCheckout(folder) ? worktreeName(folder) : suffixes.get(folder.id);
  // The menu is as wide as its fullest listed row needs (composerLocation.css `.acpmux-folder-fit`).
  // The list mounts only the rows in view and places them itself, so the rows give the popup no
  // width: the longest rows' words are listed once more, unseen, and the browser measures those.
  // Only while open: a closed menu measures nothing, whatever re-renders its composer.
  // Every worktree a repository can open counts too, open or not, in one order that expanding never changes: the
  // kept widest lines are picked by an estimate, so a different order on expand measured a different line and the
  // width moved a few px.
  const worktreeLines: FitLine[] = open
    ? rows.flatMap(({ group, worktrees }) =>
        (typed ? worktrees : group.members.filter((member) => member !== group.lead)).map((member): FitLine => ({
          text: worktreeLabel(member),
          kind: "worktree",
        })),
      )
    : [];
  if (open && !typed && worktreeActionGroup !== undefined)
    worktreeLines.push({ text: t("project.newWorktree"), kind: "worktree" });
  const fit = widestLines([
    ...(open ? listValues : [])
      .filter((value) => value !== ACTION_WORKTREE && !shown.get(value)?.worktree)
      .map((value): FitLine => {
        if (value === ACTION_NONE) return { text: t("project.noFolder"), kind: "row" };
        const repo = githubRows.get(value);
        if (repo) return { text: repo.fullName, kind: repo.private ? "lock" : "row" };
        const folder = cloudRows.get(value);
        if (folder) return { text: folder.label, kind: "row" };
        const place = shown.get(value);
        if (!place) return { text: t("project.usePath", { path: value }), kind: "row" };
        const suffix = leadSuffix(place.group.lead);
        const name = suffix ? `${place.group.name} · ${suffix}` : place.group.name;
        return place.disclosure
          ? { text: place.disclosure.count ? `${name} ${place.disclosure.count}` : name, kind: "count" }
          : { text: name, kind: "row" };
      }),
    ...worktreeLines,
  ]);
  const setOpen = (next: boolean) => {
    if (next && sourcesOpen) return;
    if (next) {
      setHighlightBy("none");
      if (!open) {
        // The repositories added as projects, as they are now: one added since the last open is listed.
        // Only where a repository can be picked: none in a Sandboxed chat (no GitHub source), or a menu with no sources.
        setAdded(github ? readAddedRepos() : NO_REPOS);
        // The closed menu grouped nothing: find the current folder's repository once, at the open.
        const opening = groupByRepo(
          folders.filter((folder) => !/^\/+$/.test(folder.id)),
          current,
          "main",
        ).find((group) => group.members.some((member) => member.id === current));
        if (opening && opening.lead.id !== current) setExpanded(new Set([opening.key]));
      }
    }
    if (!next) {
      setQuery("");
      setExpanded(new Set());
      setSearchCollapsed(new Set());
      setHeldHeight(undefined);
    }
    setPopoverOpen(next, folderMenuShortest(listValues.length, actionCount));
  };
  const press = usePopoverTrigger(open, setOpen);
  useLocationOpener(menu, () => setOpen(true));
  const shortcut = useLocationShortcut(menu);
  const close = () => {
    setOpen(false);
    if (escaped.current) trigger.current?.focus();
    escaped.current = false;
  };
  const browse = () => {
    close();
    void Promise.resolve()
      .then(() => onBrowse?.())
      .catch(() => undefined);
  };
  const submit = (value: string) => {
    if (value === ACTION_ADD) {
      // GitHub is read here, as its repositories are offered, never before (cmux#53226).
      github?.onOpen();
      if (github?.state.query) github.onSearch(null);
      close();
      setSourcesOpen(true);
      return;
    }
    if (value === ACTION_BROWSE) {
      browse();
      return;
    }
    const cloudFolder = cloudRows.get(value);
    const repo = githubRows.get(value);
    close();
    if (value === ACTION_NONE) onNoProject?.();
    else if (value === ACTION_WORKTREE) onNewWorktree?.();
    else if (cloudFolder) sources?.onCloudFolder?.(cloudFolder);
    else if (repo) {
      rememberAddedRepo(repo);
      const folder = githubFolder(repo.fullName);
      if (folder !== current) onPick(folder);
    } else if (value && value !== current && (shown.has(value) || value === typedPath)) onPick(value);
  };
  const row = (value: string) => {
    if (value === ACTION_ADD || value === ACTION_BROWSE)
      return (
        <span className="acpmux-location-action" data-choose={value === ACTION_BROWSE ? "" : undefined}>
          <span className="acpmux-location-action-icon" aria-hidden="true">
            <PlusIcon />
          </span>
          <span className="acpmux-menu-label">{t(value === ACTION_ADD ? "project.add" : "composer.addFolder")}</span>
        </span>
      );
    if (value === ACTION_NONE)
      return (
        <span className="acpmux-location-row" data-no-folder="">
          <span className="acpmux-location-action-icon" aria-hidden="true">
            <MenuFolderIcon />
          </span>
          <span className="acpmux-menu-label">{t("project.noFolder")}</span>
          {!current && !newProject && <CheckIcon />}
        </span>
      );
    if (value === ACTION_WORKTREE)
      return (
        <span className="acpmux-location-row" data-worktree="">
          <span className="acpmux-location-branch-icon" aria-hidden="true">
            <BranchIcon />
          </span>
          <span className="acpmux-menu-label">{t("project.newWorktree")}</span>
        </span>
      );
    const githubRepo = githubRows.get(value);
    const cloudFolder = cloudRows.get(value);
    if (githubRepo || cloudFolder) {
      const checked = githubRepo
        ? githubFolder(githubRepo.fullName) === current
        : cloudFolder?.id === current && cloudFolder?.peer === currentPeer;
      return (
        <span
          className="acpmux-location-row"
          // tooltip-allow: machine folders can share a name and their path can exceed the menu width.
          title={cloudFolder?.id}
          data-section={sections.get(value)}
          data-divider={dividerOf(value)}
          data-github={githubRepo ? "" : undefined}
          data-current={checked ? "" : undefined}
        >
          <span className="acpmux-location-action-icon" aria-hidden="true">
            {githubRepo ? <GitHubGlyph /> : <MenuFolderIcon />}
          </span>
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{githubRepo?.fullName ?? cloudFolder?.label}</span>
            {cloudFolder && <span className="acpmux-menu-description">{cloudFolder.id}</span>}
          </span>
          {githubRepo?.private && (
            <span className="acpmux-location-lock">
              <LockIcon />
              <span className="acpmux-env-status-text">{t("composer.githubPrivate")}</span>
            </span>
          )}
          {cloudFolder?.stage && <span className="acpmux-source-status">{cloudFolder.stage}</span>}
          <span className="acpmux-location-check" aria-hidden="true">
            {checked && <CheckIcon />}
          </span>
        </span>
      );
    }
    const place = shown.get(value);
    if (!place)
      return (
        <span className="acpmux-location-row" data-use-path="">
          <span className="acpmux-location-action-icon" aria-hidden="true">
            <MenuFolderIcon />
          </span>
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
            <span className="acpmux-menu-label">{worktreeLabel(worktree)}</span>
          </span>
          <span className="acpmux-location-check" aria-hidden="true">
            {worktree.id === current && <CheckIcon />}
          </span>
        </span>
      );
    const folder = group.lead;
    const suffix = leadSuffix(folder);
    const { disclosure } = place;
    const repo = folderRepo(folder);
    // With Cloud picked the chip names a clone of a GitHub repository by that repository.
    const leadCurrent =
      folder.id === current ||
      (repo?.github !== undefined && githubFolderRepo(current)?.toLowerCase() === repo.github.toLowerCase());
    return (
      <span
        className="acpmux-location-row"
        // tooltip-allow: the row shows the folder's name; the tooltip is its full path
        title={folder.id}
        data-current={leadCurrent ? "" : undefined}
        data-expanded={disclosure ? String(disclosure.open) : undefined}
        data-github={repo?.github ? "" : undefined}
      >
        {repo?.github ? (
          // A clone of a GitHub repository reads as one, like a repository added as a project.
          <span className="acpmux-location-action-icon" aria-hidden="true">
            <GitHubGlyph />
          </span>
        ) : (
          <ProjectBadge project={{ cwd: folder.id, label: folder.label, repo }} />
        )}
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
        {disclosure && (
          // The count opens or closes the repository's other worktrees; a press here never picks
          // the row (the arrows do the same from the field).
          <button
            className="acpmux-location-worktrees"
            type="button"
            tabIndex={-1}
            aria-label={disclosureLabel(disclosure)}
            aria-expanded={disclosure.open}
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
              const menuBox = event.currentTarget.closest<HTMLElement>(".acpmux-folder-popover");
              if (menuBox && heldHeight === undefined) {
                setHeldHeight(Math.round(menuBox.getBoundingClientRect().height));
                menuBox.addEventListener("pointerleave", () => setHeldHeight(undefined), { once: true });
              }
              toggle(group.key, !disclosure.open);
            }}
          >
            <BranchIcon />
            {disclosure.count || undefined}
            <ChevronRightIcon />
          </button>
        )}
        <span className="acpmux-location-check" aria-hidden="true">
          {leadCurrent && <CheckIcon />}
        </span>
      </span>
    );
  };
  // With a search in progress, horizontal arrows edit text until the person navigates to a row.
  const arrow = (key: string) => {
    if ((typed && highlightBy !== "keyboard") || (key !== "ArrowRight" && key !== "ArrowLeft")) return false;
    const place = highlighted.current ? shown.get(highlighted.current) : undefined;
    if (!place?.disclosure) return false;
    const open = key === "ArrowRight";
    if (place.disclosure.open === open) return false;
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
        title={pendingRepository || current || label}
        data-tooltip-shortcut={shortcut}
        {...press}
      >
        {cloningName ? (
          <span className="acpmux-source-cloning">
            <GitHubGlyph /> {cloningName} · {t("source.url.cloning")}
          </span>
        ) : pendingRepository ? (
          <span className="acpmux-source-cloning" data-pending-repository="">
            <GitHubGlyph /> {pendingRepository}
          </span>
        ) : (
          face
        )}
      </button>
      <Popover
        id={press["aria-controls"]}
        open={open}
        onOpenChange={(next, details) => {
          if (!next && details?.escape) {
            escaped.current = true;
            close();
          } else setOpen(next);
        }}
        anchor={open ? anchor : null}
        label={label}
        className={
          "acpmux-menu acpmux-location-menu acpmux-folder-popover" +
          // Short of room the list keeps up to three of its rows over the actions (composerLocation.css).
          ` acpmux-folder-rows-${Math.min(3, listValues.length)}` +
          (sources ? " acpmux-folder-choices" : "") +
          (highlightBy === "none" && !typed ? " acpmux-folder-highlight-auto" : "") +
          (highlightBy === "keyboard" ? " acpmux-folder-highlight-keyboard" : "")
        }
        style={
          {
            "--acpmux-folder-held-height": heldHeight === undefined ? undefined : `${heldHeight}px`,
          } as React.CSSProperties
        }
        side={side}
        flip={flip}
        finalFocus={false}
        resize={{ id: "composer.folder", minHeight: 250, fitHeight: true }}
      >
        <div className="acpmux-folder-fit-clip">
          <div className="acpmux-folder-fit" aria-hidden="true">
            {fit.map((line) => (
              <span key={line.kind + line.text} data-text={line.text} data-kind={line.kind} />
            ))}
          </div>
        </div>
        <Combobox
          rootClassName="acpmux-folder-body"
          suggestions={suggestions}
          pinnedSuggestions={pinned}
          pinnedPlacement="bottom"
          cancelOnBlur={false}
          inputRef={focusFolderField}
          onQuery={(next) => {
            setQuery(next);
            if (next.trim() !== typed && searchCollapsed.size) setSearchCollapsed(new Set());
          }}
          onSubmit={submit}
          onCancel={close}
          onHighlight={(value, by) => {
            highlighted.current = value;
            setHighlightBy(by);
          }}
          // Tab completes a folder's path into the field, never an action's or a GitHub row's.
          onCommand={(event) => {
            if (event.nativeEvent.isComposing) return;
            const worktreeArrow =
              !event.altKey && !event.metaKey && !event.ctrlKey && !event.shiftKey && arrow(event.key);
            if (event.key === "Escape") escaped.current = true;
            if (worktreeArrow) event.preventDefault();
            if (
              event.key === "Tab" &&
              !event.shiftKey &&
              (highlighted.current ?? listValues[0] ?? pinned[0])?.startsWith("\u0000")
            ) {
              event.preventDefault();
              event.preventBaseUIHandler?.();
            }
          }}
          label={t("composer.folderSearch")}
          placeholder={t("composer.folderSearch")}
          inputClassName="acpmux-location-search"
          listClassName="acpmux-location-folders"
          itemClassName="acpmux-menu-item"
          isItemCurrent={(value) => shown.has(value) && value === current}
          itemLabel={(value) => {
            const place = shown.get(value);
            if (!place?.disclosure) return undefined;
            return [place.group.name, leadSuffix(place.group.lead), disclosureLabel(place.disclosure)]
              .filter(Boolean)
              .join(" · ");
          }}
          renderItem={row}
          autoHighlight
          inline
          // Thousands of projects (Leo 2026-11-04): only the rows in view mount.
          // A heading changes a row's margin, not its box: the row is measured again when it changes.
          // A heading with its hairline is taller than one without: either change measures it again.
          virtualRows={{
            estimate: 28,
            sizeKey: (value) => (sections.get(value) ?? "") + (dividerOf(value) ?? "\u0000"),
          }}
          // The empty line sits in the list's place, over the actions.
          listEnd={
            listValues.length === 0 ? (
              <div className="acpmux-location-empty">{t(typed ? "composer.folderNone" : "composer.folderNoneYet")}</div>
            ) : undefined
          }
        />
        {extra && !cloud && <ExtraFolderList folders={extra.folders} onRemove={extra.onRemove} />}
      </Popover>
      {sources && sourcesOpen && (
        <SourcePicker
          open
          options={sources}
          current={current}
          currentPeer={currentPeer}
          onClose={() => setSourcesOpen(false)}
          onBrowse={onBrowse && browse}
          onPick={(value) => {
            // A GitHub repository added as a project is listed in this menu from now on (cmux#53226).
            const name = githubFolderRepo(value);
            if (name)
              rememberAddedRepo({
                fullName: name,
                private: github?.state.repos?.find((repo) => repo.fullName === name)?.private ?? false,
              });
            if (value !== current) onPick(value);
          }}
          onCloning={setCloning}
          returnFocus={trigger}
        />
      )}
    </span>
  );
}

/// The list's values in order: each
/// repository's rows (its lead, New Worktree, its open worktrees) kept together and placed by when its newest
/// folder was used, the added repositories among them by theirs; with words typed, the folders in the search's
/// order, the typed path, then the repositories that match. Cloud adds each machine's folders after them.
function orderedRows({
  cloud,
  cloudRows,
  githubRows,
  shown,
  typed,
  typedPath,
}: {
  cloud: boolean;
  cloudRows: ReadonlyMap<string, unknown>;
  githubRows: ReadonlyMap<string, AddedRepo>;
  shown: ReadonlyMap<string, { group: { key: string; members: readonly FolderChoice[] } }>;
  typed: string;
  typedPath: string | undefined;
}): string[] {
  const repos: { repo: AddedRepo; block: string[] }[] = [];
  githubRows.forEach((repo, value) => repos.push({ repo, block: [value] }));
  const blocks: { block: string[]; at: number | undefined }[] = [];
  let previous: string | undefined;
  shown.forEach((place, value) => {
    const group = place.group;
    if (group.key !== previous) {
      blocks.push({ block: [], at: newestUse(group.members) });
      previous = group.key;
    }
    blocks[blocks.length - 1]!.block.push(value);
  });
  const path = typedPath ? [typedPath] : [];
  // Cloud: the machines' own folders under their headings, after the one list.
  const machines = cloud ? [...cloudRows.keys()] : [];
  if (typed)
    return [...blocks.flatMap(({ block }) => block), ...path, ...repos.flatMap(({ block }) => block), ...machines];
  return [...mergeByRecentUse(blocks, repos).flat(), ...path, ...machines];
}

/// When a chat here last worked in any of `members`, if one did.
function newestUse(members: readonly FolderChoice[]): number | undefined {
  let at: number | undefined;
  members.forEach((member) => {
    const used = folderUsedAt(member.id);
    if (used !== undefined && (at === undefined || used > at)) at = used;
  });
  return at;
}

function focusFolderField(input: HTMLInputElement | null): void {
  input?.focus();
}

function worktreeLabel(folder: FolderChoice): string {
  const name = worktreeName(folder);
  const prefix = "worktrees/";
  return name.startsWith(prefix) && name === belowCheckout(folder) ? name.slice(prefix.length) : name;
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
const FIT_KIND_LETTERS: Record<FitLine["kind"], number> = { row: 0, count: 7, worktree: 3, lock: 3 };

/// An action row's value: never a path.
const ACTION = "\u0000action:";
const ACTION_ADD = ACTION + "add";
const ACTION_BROWSE = ACTION + "browse";
const ACTION_NONE = ACTION + "none";
const ACTION_WORKTREE = ACTION + "worktree";
const GITHUB_REPO = "\u0000github:repo:";

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
      className="acpmux-icon acpmux-location-worktrees-chevron"
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
