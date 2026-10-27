// The changes one turn made, ported from the changes pane in the agent-pane reference prototype
// (src/changes/parts/Header.tsx, DiffList.tsx and ChangesTree.tsx): a pill with the totals,
// a round toolbar, stacked per-file diffs on @pierre/diffs with a custom file header, and a
// filterable @pierre/trees file tree.
import React, { useEffect, useMemo, useRef, useState } from "react";
import { useStableCallback } from "@pierre/diffs/react";
import type { DiffHunk, TurnFile } from "./diff";
import { registerAgentDiffTheme } from "./diffTheme";
import { ChevronLeft, CollapseAll, Panels, SplitView, Wrap } from "./changeIcons";
import { ChangedFilesTree } from "./changes/ChangedFilesTree";
import { Counts } from "./changes/Counts";
import { DiffKeyHints } from "./changes/DiffKeyHints";
import { EditBlock, type DiffLayout } from "./changes/EditBlock";
import { addressPrompt, threadId, type AddressState, type ReviewThread } from "./changes/reviewThreads";
import { ReviewThread as ReviewThreadView } from "./changes/ReviewThread";
import type { HunkReview } from "./changes/hunkReview";
import type { FileActions, OpenTarget } from "./changes/FileHeader";
import { LoadState } from "./changes/LoadState";
import { applyCommand } from "./changes/applyCommand";
import { BranchPill } from "./changes/BranchPill";
import { PullRequestButton } from "./changes/PullRequestButton";
import { copyText } from "./conversation/clipboard";
import { changeSetFiles, type ChangeScope, type ChangesSource } from "./changes/model";
import { OptionsMenu, type OptionsRow } from "./changes/OptionsMenu";
import { RevertBar } from "./changes/RevertBar";
import { ScopeMenu } from "./changes/ScopeMenu";
import { TrackedOnlyBanner } from "./changes/TrackedOnlyBanner";
import { useDiffFind, type DiffFindHandle } from "./changes/diffFind";
import { ChatFindBar } from "./conversation/ChatFindBar";
import { useDiffKeys } from "./changes/useDiffKeys";
import { useScopeChanges } from "./changes/useScopeChanges";
import { useT } from "./i18n";
import { fileKind, missingTests, orderByKind } from "../../fileKinds";
import { GitToolbarButtons, GitWriteBar } from "./changes/GitActions";
import type { GitWriteOp, WriteKeys } from "./changes/gitWrite";
import { useGitWrite } from "./changes/useGitWrite";

const LAYOUT_KEY = "cmux.acpmux.diffLayout";
const WRAP_KEY = "cmux.acpmux.diffWrap";
const TREE_KEY = "cmux.acpmux.diffTree";

/// The reader's view choices last as long as this pane's storage allows.
function stored(key: string): string | null {
  try {
    return window.localStorage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}
function store(key: string, value: string) {
  try {
    window.localStorage?.setItem(key, value);
  } catch {
    /* the choice lasts this pane only */
  }
}

type Tool = "collapse" | "wrap" | "split" | "tree";

/// `path` with its `.` and `..` steps applied; undefined when a relative path steps above its start.
function resolved(path: string): string | undefined {
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part !== "..") parts.push(part);
    else if (parts.length > 0) parts.pop();
    else if (!path.startsWith("/")) return undefined;
  }
  return (path.startsWith("/") ? "/" : "") + parts.join("/");
}

/// `path` with macOS's /private spelling of /tmp, /var and /etc read as the short one: acpmux's
/// canonical path names the real one (/private/tmp/repo) where the chat's folder may not (/tmp/repo).
function unaliased(path: string): string {
  return path.replace(/^\/private(?=\/(?:tmp|var|etc)(?:\/|$))/, "");
}

/// The path a file's kind (fileKinds.ts) is read from, so a folder above the project never names it
/// (a repository under `~/tests/` is not all tests): a git scope's from the repository's top; a
/// turn's from the chat's folder `root`, as its display path drops the folder its files share (one
/// file under `tests/` shows as `helpers.py`). A turn's path is matched under either spelling
/// acpmux recorded, and /private/tmp is /tmp on either side (`unaliased`). A turn's file outside
/// that folder, or with no folder known, is read by its name alone.
export function kindPath(scope: ChangeScope, file: TurnFile, root: string | undefined): string {
  if (scope !== "lastTurn") return file.displayPath;
  const real = root && resolved(root);
  const top = real && unaliased(real);
  for (const spelling of [file.canonical, file.path]) {
    if (!spelling) continue;
    // A relative path is the agent's, under its folder.
    const full = spelling.startsWith("/") ? resolved(spelling) : resolved(top ? `${top}/${spelling}` : spelling);
    const path = full && unaliased(full);
    if (!path) continue;
    // A relative path is under the chat's folder only when that folder is known.
    if (!path.startsWith("/")) {
      if (top) return path;
      continue;
    }
    if (top && path.startsWith(top === "/" ? "/" : `${top}/`)) return path.slice(top === "/" ? 1 : top.length + 1);
  }
  return file.path.slice(file.path.lastIndexOf("/") + 1);
}

/// `path` as an absolute path: a relative one is the agent's, under the chat's folder `root`, and
/// /private/tmp reads as /tmp (`unaliased`).
function absolute(path: string, root: string | undefined): string | undefined {
  const top = root && resolved(root);
  const full = path.startsWith("/") ? resolved(path) : top ? resolved(`${top}/${path}`) : undefined;
  return full && unaliased(full);
}

/// The one name a file has under every spelling: its absolute path (canonical first), else its path.
function fileIdentity(file: TurnFile, root: string | undefined): string {
  for (const spelling of [file.canonical, file.path]) {
    const full = spelling === undefined ? undefined : absolute(spelling, root);
    if (full) return full;
  }
  return file.path;
}

/// The listed file `path` names, by its path or canonical path, as written or resolved from the
/// chat's folder: a tool call's relative path opens the view, then the loaded checkpoint lists
/// the same file by its absolute path. `path` itself when no listed file is it.
export function listedPath(files: readonly TurnFile[], path: string, root: string | undefined): string {
  const exact = files.find((file) => file.path === path || file.canonical === path);
  if (exact) return exact.path;
  const wanted = absolute(path, root);
  if (!wanted) return path;
  const match = files.find((file) =>
    [file.path, file.canonical].some((spelling) => spelling !== undefined && absolute(spelling, root) === wanted),
  );
  return match?.path ?? path;
}

export function bindDiffPanelEscape(panel: HTMLElement, onClose: () => void): () => void {
  const ownerDocument = panel.ownerDocument;
  const ownerWindow = ownerDocument.defaultView;
  if (!ownerWindow) return () => {};
  const close = (event: KeyboardEvent) => {
    const focus = ownerDocument.activeElement;
    if (event.key !== "Escape" || event.defaultPrevented || focus instanceof ownerWindow.HTMLInputElement) return;
    if (!focus || focus === ownerDocument.body || panel.contains(focus)) {
      event.preventDefault();
      onClose();
    }
  };
  ownerWindow.addEventListener("keydown", close);
  return () => ownerWindow.removeEventListener("keydown", close);
}

/// The changes one turn's tool calls made, file by file, or a git scope of the session's
/// repository from `source`. Back or Escape returns to the transcript. With `review`, the last
/// turn's hunks can each be accepted or rejected, and the rejected ones sent back to the agent.
export function DiffPanel({
  files: turnFiles,
  initialPath,
  root,
  onClose,
  source,
  onOpenFile,
  checkpointAction,
  checkpointReview,
  review,
  reviewFiles,
  turn,
  gitIntent,
  onGitIntentHandled,
  writeKeys,
  onAddressThread,
  findHandle,
}: {
  files: TurnFile[];
  initialPath?: string;
  /// The chat's folder: a Last turn file's kind is read from its path in it (`kindPath`).
  root?: string;
  onClose: () => void;
  source?: ChangesSource;
  /// Asks the host to open a changed file; rejects with the host's reason when it can't.
  onOpenFile?: (path: string, where: OpenTarget) => Promise<unknown>;
  checkpointAction?: React.ReactNode;
  checkpointReview?: React.ReactNode;
  review?: HunkReview;
  /// Tool-call files remain the source of revert patches when Last turn is showing a checkpoint.
  reviewFiles?: TurnFile[];
  /// Where Last turn's files came from, and why a checkpoint isn't shown when one was expected.
  turn?: { source: "checkpoint" | "tools"; note?: string; partial?: true };
  /// The palette's Commit or Push (`agentPane.git.*`): each new nonce opens the commit form or
  /// pushes, as the toolbar's buttons do.
  gitIntent?: { op: GitWriteOp; nonce: number };
  /// The view took `gitIntent`; the page clears it so a later view never replays it.
  onGitIntentHandled?: () => void;
  /// The session's idempotency keys, kept by the page across a close and reopen of the view.
  writeKeys?: WriteKeys;
  /// Address on a review thread (cx-ncc.77.3): sends the agent a prompt to address it; resolves
  /// once the chat took the prompt (not when the turn ends), rejects when it refused it.
  onAddressThread?: (prompt: string) => Promise<unknown>;
  /// Where the page reaches this view's find (Cmd-F and the Edit menu's Find commands).
  findHandle?: React.MutableRefObject<DiffFindHandle | undefined>;
}) {
  const t = useT();
  registerAgentDiffTheme();
  const [scope, setScope] = useState<ChangeScope>("lastTurn");
  const { load, retry, branch, threads } = useScopeChanges(source, scope);
  const [commitOpen, setCommitOpen] = useState(false);
  // A commit closes the form and reloads the scope; a push changes only the branch state.
  const git = useGitWrite(
    source,
    (op) => {
      if (op === "commit") setCommitOpen(false);
      if (op !== "push") retry();
    },
    writeKeys,
  );
  const commitMessage = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    if (commitOpen) commitMessage.current?.focus();
  }, [commitOpen]);
  const handledIntent = useRef<number | undefined>(undefined);
  useEffect(() => {
    if (!gitIntent || handledIntent.current === gitIntent.nonce) return;
    handledIntent.current = gitIntent.nonce;
    if (gitIntent.op === "push") void git.push();
    else if (commitOpen) commitMessage.current?.focus();
    else setCommitOpen(true);
    onGitIntentHandled?.();
  }, [gitIntent, git, commitOpen, onGitIntentHandled]);
  const scopeFiles = useMemo(() => (load.state === "loaded" ? changeSetFiles(load.changeSet) : []), [load]);
  // The delineated diff, as the diff viewer and the pull request card read a change
  // (fileKinds.ts): code first, then tests, mocks, docs, evals and generated files.
  const files = useMemo(
    () => [...orderByKind(scope === "lastTurn" ? turnFiles : scopeFiles, (file) => kindPath(scope, file, root))],
    [scope, turnFiles, scopeFiles, root],
  );
  const threadsByPath = useMemo(() => {
    const byPath = new Map<string, ReviewThread[]>();
    for (const thread of threads ?? []) byPath.set(thread.path, [...(byPath.get(thread.path) ?? []), thread]);
    return byPath;
  }, [threads]);
  // Address's state per thread lives here, above the scope's reloads and Pierre's annotation
  // slots, so a thread sent once stays sent and never offers a second send.
  const [addressStates, setAddressStates] = useState<ReadonlyMap<string, AddressState>>(() => new Map());
  const addressing = useRef(new Set<string>());
  const runAddress = useStableCallback((thread: ReviewThread) => {
    const id = threadId(thread);
    if (!onAddressThread || addressing.current.has(id)) return;
    addressing.current.add(id);
    const mark = (state: AddressState) => setAddressStates((current) => new Map(current).set(id, state));
    mark({ state: "sending" });
    onAddressThread(addressPrompt(thread)).then(
      () => mark({ state: "sent" }),
      (error: unknown) => {
        addressing.current.delete(id);
        mark({
          state: "failed",
          message: error instanceof Error && error.message ? error.message : t("review.sendFailed"),
        });
      },
    );
  });
  const address = onAddressThread ? { states: addressStates, run: runAddress } : undefined;
  /// Threads on files the scope does not list (reverted here, or outside its diff), shown first.
  const elsewhere = useMemo(() => {
    const listed = new Set(files.map((file) => file.displayPath));
    return (threads ?? []).filter((thread) => !listed.has(thread.path));
  }, [threads, files]);
  /// A git scope's body before its files: loading, failed or empty.
  const scopeState =
    scope === "lastTurn" || (load.state === "loaded" && files.length > 0)
      ? undefined
      : load.state === "loaded"
        ? "empty"
        : load.state;
  // Code changed and no test did: the pull request card's warning, in its words. Not when the
  // host left files out (a partial git answer or checkpoint): an omitted file may be the test.
  const partial =
    scope === "lastTurn"
      ? turn?.partial === true
      : load.state === "loaded" &&
        ((load.changeSet.filesOmitted ?? 0) > 0 || (load.changeSet.untrackedSkipped ?? 0) > 0);
  const noTests = !scopeState && !partial && missingTests(files.map((file) => ({ path: kindPath(scope, file, root) })));
  const [layout, setLayout] = useState<DiffLayout>(() => (stored(LAYOUT_KEY) === "split" ? "split" : "unified"));
  const [wrap, setWrap] = useState(() => stored(WRAP_KEY) === "on");
  const [showTree, setShowTree] = useState(() => stored(TREE_KEY) !== "off");
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(() => new Set());
  // Generated files and lockfiles start folded, as the diff viewer defers them; the reader opens
  // one from its header or the tree. Each file folds once, so one the reader opened stays open,
  // and the file the view was opened on is never folded.
  // A file is remembered by its absolute path, so the checkpoint's absolute spelling of a file a
  // tool call named relatively is the same file: it does not fold again, and a fold or an open the
  // reader chose moves to the new spelling.
  const generated = useMemo(() => {
    const seen = new Set<string>();
    return files
      .filter((file) => fileKind(kindPath(scope, file, root)) === "generated")
      .map((file) => ({ path: file.path, id: fileIdentity(file, root) }))
      .filter((file) => !seen.has(file.id) && Boolean(seen.add(file.id)));
  }, [files, scope, root]);
  // Each generated file's identity, with the path the list last named it by.
  const [folded, setFolded] = useState<ReadonlyMap<string, string>>(() => new Map());
  // The file the view was opened on, as the list names it now (a tool call's relative path, then
  // the checkpoint's absolute one).
  const openedPath = initialPath === undefined ? undefined : listedPath(files, initialPath, root);
  const changed = generated.filter((file) => folded.get(file.id) !== file.path);
  if (changed.length > 0) {
    const next = new Map(folded);
    const fold: string[] = [];
    const moved: [string, string][] = [];
    for (const file of changed) {
      const before = folded.get(file.id);
      next.set(file.id, file.path);
      if (before !== undefined) moved.push([before, file.path]);
      else if (file.path !== openedPath) fold.push(file.path);
    }
    setFolded(next);
    setCollapsed((current) => {
      const out = new Set(current);
      for (const [before, after] of moved) if (out.delete(before)) out.add(after);
      for (const path of fold) out.add(path);
      return out;
    });
  }
  const [viewed, setViewed] = useState<ReadonlySet<string>>(() => new Set());
  const [selected, setSelected] = useState<string | undefined>(initialPath ?? files[0]?.path);
  const body = useRef<HTMLDivElement>(null);
  const back = useRef<HTMLButtonElement>(null);
  const focusAfter = useRef<string | undefined>(undefined);
  // Decisions are keyed by the turn's tool calls. Checkpoint hunks carry the matching keys when
  // the net diff still contains a tool change, while formatter-only hunks remain read-only.
  const hunkReview = scope === "lastTurn" ? review : undefined;
  const turnNote = scope === "lastTurn" ? turn?.note : undefined;
  const totals = useMemo(
    () =>
      files.reduce(
        (sum, file) => ({
          additions: sum.additions + file.additions,
          deletions: sum.deletions + file.deletions,
        }),
        { additions: 0, deletions: 0 },
      ),
    [files],
  );
  const reveal = (path: string) => {
    setSelected(path);
    const section = [...(body.current?.querySelectorAll<HTMLElement>(".acpmux-diff-file") ?? [])].find(
      (node) => node.dataset.path === path,
    );
    section?.scrollIntoView?.({ block: "start" });
  };
  // Diffs paint after the highlighter loads, moving the file below them; the opened file is
  // revealed again after each paint until the reader scrolls, types or picks another file.
  const revealing = useRef(initialPath);
  const stopRevealing = () => {
    revealing.current = undefined;
  };
  const revealFromTree = useStableCallback((path: string) => {
    revealing.current = path;
    // A file picked in the tree opens if it was collapsed.
    setCollapsed((current) => {
      if (!current.has(path)) return current;
      const next = new Set(current);
      next.delete(path);
      return next;
    });
    reveal(path);
  });
  // Wheel, pointer or key input in the diffs means the reader is moving on their own.
  useEffect(() => {
    const node = body.current;
    if (!node) return;
    const stop = () => {
      revealing.current = undefined;
    };
    for (const type of ["wheel", "pointerdown", "keydown"]) node.addEventListener(type, stop, { passive: true });
    return () => {
      for (const type of ["wheel", "pointerdown", "keydown"]) node.removeEventListener(type, stop);
    };
  }, []);
  const onPainted = useStableCallback(() => {
    if (revealing.current) reveal(listedPath(files, revealing.current, root));
  });
  // The file the view opens on shows, even one folded as generated, under the path the list
  // names it by (a relative tool path opens a checkpoint's absolute one).
  const openInitial = useStableCallback((path: string) => {
    const listed = listedPath(files, path, root);
    setCollapsed((current) => {
      if (!current.has(listed)) return current;
      const next = new Set(current);
      next.delete(listed);
      return next;
    });
    reveal(listed);
  });
  // Focus moves into the view, so keys reach it and a screen reader announces it.
  useEffect(() => {
    back.current?.focus();
    // Another file opened in the open view: later paints keep it in view, not the first one.
    revealing.current = initialPath;
    if (initialPath) openInitial(initialPath);
  }, [initialPath, openInitial]);
  // Escape closes the view while focus is in it (or nowhere), not while typing in the composer
  // or the file filter.
  const panel = useRef<HTMLElement>(null);
  const find = useDiffFind(body);
  useEffect(() => {
    if (!findHandle) return undefined;
    findHandle.current = {
      find,
      owns: () => {
        const node = panel.current;
        if (!node) return false;
        if (node.contains(node.ownerDocument.activeElement)) return true;
        // A narrow pane's view covers the transcript (hidden beneath it).
        const transcript = node.ownerDocument.querySelector(".acpmux-scroll");
        return !transcript || getComputedStyle(transcript).visibility === "hidden";
      },
    };
  }, [findHandle, find]);
  useEffect(
    () => () => {
      if (findHandle) findHandle.current = undefined;
    },
    [findHandle],
  );
  // j/k move between files as picking them in the tree does; n/p between changes.
  const selectedFile = useStableCallback(() => selected);
  useEffect(() => {
    const node = panel.current;
    return node ? bindDiffPanelEscape(node, onClose) : undefined;
  }, [onClose]);
  // Why the last open failed, until the next open or another scope. Only the latest open's
  // failure shows: an earlier one that fails late was overtaken.
  const [openFailure, setOpenFailure] = useState<string>();
  const latestOpen = useRef(0);
  const openFile = useStableCallback((path: string, where: OpenTarget) => {
    const request = ++latestOpen.current;
    setOpenFailure(undefined);
    const opening = onOpenFile ? onOpenFile(path, where) : Promise.reject(new Error(t("changes.openFailed")));
    opening.catch((error: unknown) => {
      if (request !== latestOpen.current) return;
      setOpenFailure(error instanceof Error && error.message ? error.message : t("changes.openFailed"));
    });
  });
  // Stage or Unstage a file (cx-tcwj): Unstaged and Uncommitted stage it, Staged unstages it,
  // and the scope reloads. A failure says why where a failed open does. The view names a file by
  // its absolute path; git.stage takes it from the repository's top, as git.diff listed it. A
  // rename is both of its paths, or half of it would stay behind.
  const unstages = scope === "staged" ? true : scope === "unstaged" || scope === "uncommitted" ? false : undefined;
  // Stage hunk and Unstage hunk (cx-ncc.74): Unstaged stages a hunk, Staged unstages it. Uncommitted
  // has none: its hunks are HEAD against the worktree, part of which may be staged already.
  const hunkUnstages = scope === "staged" ? true : scope === "unstaged" ? false : undefined;
  const withPrevious = (
    path: string,
    changeSet: { root?: string; files: { path: string; previousPath?: string }[] },
  ) => {
    const top = changeSet.root?.replace(/\/+$/, "");
    const named = top && path.startsWith(`${top}/`) ? path.slice(top.length + 1) : path;
    const previous = changeSet.files.find((file) => file.path === named)?.previousPath;
    return previous ? [named, previous] : [named];
  };
  const changeIndex = (asked: Promise<unknown>) => {
    latestOpen.current += 1;
    setOpenFailure(undefined);
    asked.then(retry, (error: unknown) =>
      setOpenFailure(error instanceof Error && error.message ? error.message : t("changes.stageFailed")),
    );
  };
  const stageFile = useStableCallback((path: string) => {
    if (!source?.stage || unstages === undefined || load.state !== "loaded") return;
    changeIndex(source.stage(withPrevious(path, load.changeSet), unstages));
  });
  const stageHunk = useStableCallback((path: string, hunk: DiffHunk) => {
    if (!source?.stageHunk || hunkUnstages === undefined || load.state !== "loaded") return;
    const lines = hunk.lines.map((line) => (line.type === "add" ? "+" : line.type === "del" ? "-" : " ") + line.text);
    changeIndex(source.stageHunk(withPrevious(path, load.changeSet), lines, hunkUnstages));
  });
  // Show more lines (cx-ncc.85): each file is read whole once per load of the scope, when it
  // comes into view; a rename's old name would be lost from a one-path read, so it isn't.
  const wholeReads = useRef<{
    load: typeof load;
    reads: Map<string, ReturnType<NonNullable<FileActions["wholeFile"]>>>;
  }>(undefined);
  const wholeFile = useStableCallback((path: string) => {
    if (!source?.wholeFile || scope === "lastTurn" || load.state !== "loaded") return Promise.resolve(undefined);
    const named = withPrevious(path, load.changeSet);
    if (named.length !== 1) return Promise.resolve(undefined);
    if (wholeReads.current?.load !== load) wholeReads.current = { load, reads: new Map() };
    const { reads } = wholeReads.current;
    let read = reads.get(path);
    if (!read) {
      const name = named[0]!;
      read = source.wholeFile(scope, name).then((value) => ({ named: name, value }));
      reads.set(path, read);
    }
    return read;
  });
  const canStage = source?.stage !== undefined && unstages !== undefined;
  const canStageHunk = source?.stageHunk !== undefined && hunkUnstages !== undefined;
  const hunkKey = canStageHunk ? (hunkUnstages ? "u" : "s") : undefined;
  useDiffKeys(panel, body, revealFromTree, selectedFile, hunkKey);
  const on = useMemo<FileActions>(
    () => ({
      openFile,
      stage: canStage ? { unstage: unstages === true, run: stageFile } : undefined,
      stageHunk: canStageHunk ? { unstage: hunkUnstages === true, run: stageHunk } : undefined,
      wholeFile: source?.wholeFile && scope !== "lastTurn" ? wholeFile : undefined,
      toggleCollapsed: (path) => {
        revealing.current = undefined;
        setCollapsed((current) => {
          const next = new Set(current);
          if (next.has(path)) next.delete(path);
          else next.add(path);
          return next;
        });
      },
      // Marking a file viewed folds it away; unmarking opens it again.
      toggleViewed: (path) => {
        revealing.current = undefined;
        const marking = !viewed.has(path);
        const flip = (current: ReadonlySet<string>) => {
          const next = new Set(current);
          if (marking) next.add(path);
          else next.delete(path);
          return next;
        };
        setViewed(flip);
        setCollapsed(flip);
      },
    }),
    [viewed, openFile, canStage, unstages, stageFile, canStageHunk, hunkUnstages, stageHunk, source, scope, wholeFile],
  );
  const allCollapsed = files.length > 0 && files.every((file) => collapsed.has(file.path));
  const press = (tool: Tool) => {
    stopRevealing();
    if (tool === "collapse") setCollapsed(allCollapsed ? new Set() : new Set(files.map((file) => file.path)));
    else if (tool === "wrap") {
      setWrap(!wrap);
      store(WRAP_KEY, wrap ? "off" : "on");
    } else if (tool === "split") {
      const next = layout === "split" ? "unified" : "split";
      setLayout(next);
      store(LAYOUT_KEY, next);
    } else {
      setShowTree(!showTree);
      store(TREE_KEY, showTree ? "off" : "on");
    }
  };
  const tools: { id: Tool; label: string; icon: React.ReactNode; pressed: boolean }[] = [
    {
      id: "collapse",
      label: allCollapsed ? t("changes.expandAllFiles") : t("changes.collapseAllFiles"),
      icon: <CollapseAll />,
      pressed: allCollapsed,
    },
    { id: "wrap", label: t("changes.wrapLines"), icon: <Wrap />, pressed: wrap },
    {
      id: "split",
      label: t("changes.splitView"),
      icon: <SplitView />,
      pressed: layout === "split",
    },
    { id: "tree", label: t("changes.fileTree"), icon: <Panels />, pressed: showTree },
  ];
  // Last turn's files come from the transcript, so it neither refreshes nor has git's patches.
  const command = useMemo(
    () => (scope !== "lastTurn" && load.state === "loaded" ? applyCommand(load.changeSet) : undefined),
    [scope, load],
  );
  const skipped = scope !== "lastTurn" && load.state === "loaded" ? (load.changeSet.untrackedSkipped ?? 0) : 0;
  // A refresh drops what it replaces, so focus moves to the scope pill first.
  const refresh = () => {
    panel.current?.querySelector<HTMLElement>(".acpmux-diff-scope")?.focus();
    retry();
  };
  const options: OptionsRow[] = [
    { label: t("changes.refresh"), disabled: scope === "lastTurn", run: retry },
    { label: wrap ? t("changes.disableWrap") : t("changes.wordWrap"), run: () => press("wrap") },
    {
      label: layout === "split" ? t("changes.toUnified") : t("changes.toSplit"),
      run: () => press("split"),
    },
    {
      label: allCollapsed ? t("changes.expandAllDiffs") : t("changes.collapseAllDiffs"),
      disabled: files.length === 0,
      run: () => press("collapse"),
    },
    null,
    { label: t("changes.copyApply"), disabled: !command, run: () => command && copyText(command) },
  ];
  return (
    <section ref={panel} className="acpmux-diff-panel" data-enter="right" aria-label={t("changes.panel")}>
      <header className="acpmux-diff-header">
        <button ref={back} type="button" className="acpmux-diff-back" aria-label={t("changes.back")} onClick={onClose}>
          <ChevronLeft />
        </button>
        <ScopeMenu
          scope={scope}
          onScope={(next) => {
            if (next === scope) return;
            // Another scope is other contents: its files start open, unviewed and unpicked.
            stopRevealing();
            setScope(next);
            setCollapsed(new Set());
            setFolded(new Map());
            setViewed(new Set());
            setSelected(undefined);
            latestOpen.current += 1;
            setOpenFailure(undefined);
          }}
        >
          {files.length > 0 && <Counts additions={totals.additions} deletions={totals.deletions} />}
        </ScopeMenu>
        <div className="acpmux-diff-tools" role="toolbar" aria-label={t("changes.viewTools")}>
          <GitToolbarButtons git={git} formOpen={commitOpen} onToggleForm={() => setCommitOpen((open) => !open)} />
          {checkpointAction}
          <OptionsMenu rows={options} />
          {tools.map((tool) => (
            <button
              key={tool.id}
              type="button"
              className="acpmux-diff-tool"
              data-tool={tool.id}
              aria-label={tool.label}
              title={tool.label}
              aria-pressed={tool.pressed}
              onClick={() => press(tool.id)}
            >
              {tool.icon}
            </button>
          ))}
        </div>
      </header>
      {openFailure && (
        <div className="acpmux-diff-notice" role="alert">
          <span className="acpmux-diff-notice-text">{openFailure}</span>
          <button
            type="button"
            className="acpmux-git-secondary"
            aria-label={t("git.dismiss")}
            onClick={() => setOpenFailure(undefined)}
          >
            ×
          </button>
        </div>
      )}
      {(branch || skipped > 0 || turnNote || noTests) && (
        <div className="acpmux-diff-notes">
          {turnNote && <output className="acpmux-turn-note">{turnNote}</output>}
          {noTests && <output className="acpmux-diff-no-tests">{t("prCard.noTestsWhy")}</output>}
          {branch && (
            <div className="acpmux-branch-row">
              <BranchPill branch={branch.branch} base={branch.base} />
              {/* Keyed by branch: another checkout starts over, never showing the last pull request. */}
              {source?.pullRequest && <PullRequestButton key={branch.branch} open={source.pullRequest} />}
            </div>
          )}
          {skipped > 0 && <TrackedOnlyBanner skipped={skipped} onRefresh={refresh} />}
        </div>
      )}
      <GitWriteBar
        git={git}
        formOpen={commitOpen}
        onCloseForm={() => setCommitOpen(false)}
        messageRef={commitMessage}
        reloadKey={load.state === "loaded" ? load.changeSet : load.state}
      />
      {checkpointReview}
      <div className="acpmux-diff-main">
        <div ref={body} className="acpmux-diff-body">
          {find.open && <ChatFindBar find={find} label={t("changes.findPlaceholder")} />}
          {scopeState ? (
            <LoadState state={scopeState} onRetry={refresh} />
          ) : files.length === 0 ? (
            <div className="acpmux-muted">{t("changes.noTurnChanges")}</div>
          ) : (
            [
              elsewhere.length > 0 && (
                <section key="\u0000review" className="acpmux-review-unplaced" aria-label={t("review.otherFiles")}>
                  <h3 className="acpmux-review-heading">{t("review.otherFiles")}</h3>
                  {elsewhere.map((thread) => (
                    <ReviewThreadView
                      key={threadId(thread)}
                      thread={thread}
                      address={
                        address && {
                          state: address.states.get(threadId(thread)) ?? { state: "idle" },
                          run: () => address.run(thread),
                        }
                      }
                    />
                  ))}
                </section>
              ),
              ...files.flatMap((file) =>
                file.edits.map((edit, index) => (
                  <EditBlock
                    key={`${file.path}\u0000${edit.toolId}\u0000${index}`}
                    file={file}
                    kind={fileKind(kindPath(scope, file, root))}
                    edit={edit}
                    index={index}
                    layout={layout}
                    wrap={wrap}
                    view={{ collapsed: collapsed.has(file.path), viewed: viewed.has(file.path) }}
                    on={on}
                    onPainted={onPainted}
                    review={file.outside ? undefined : hunkReview}
                    focusAfter={focusAfter}
                    threads={threadsByPath.get(file.displayPath)}
                    address={address}
                  />
                )),
              ),
            ]
          )}
        </div>
        {showTree && (
          <nav className="acpmux-diff-tree" aria-label={t("changes.changedFiles")}>
            <ChangedFilesTree files={files} selected={selected} onSelect={revealFromTree} />
          </nav>
        )}
      </div>
      {hunkReview && (
        <RevertBar files={reviewFiles ?? files} review={hunkReview} onSent={() => back.current?.focus()} />
      )}
      {files.length > 0 && !scopeState && <DiffKeyHints hunkKey={hunkKey} />}
    </section>
  );
}
