import { useWebSwapHold } from "../../pages/shared/useWebSwapHold";
import { WEB_SWAP_KEPT_TEXT } from "../../pages/shared/webSwap";
import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useEscapingList } from "../../ui/popupHost";
import { useScrollEdges } from "../../ui/scrollEdges";
import { AgentMark as BrandMark } from "../shared/AgentMark";
import { agentDisplayName } from "./agents";
import { useLastPick } from "./lastPick";
import { ArrowUpIcon } from "./ComposerPickers";
import { useComposerLook } from "./composerLook";
import { ComposerFoot } from "./ComposerFoot";
import { useRowFit } from "./composerRowFit";
import { MarkdownField, type MarkdownFieldHandle } from "./MarkdownField";
import { useComposerSettings } from "./composerSettings";
import type { AcpmuxSnapshot } from "./model";
import { ProjectChooser, type Project } from "./ProjectChooser";
import { type BrowseRequest } from "./AddProjectPanel";
import { BROWSE_BUSY, type BrowseResult } from "./addProjectPanelModel";
import { BrowseFailure } from "./BrowseFailure";
import { ErrorDetails } from "./conversation/ErrorDetails";
import { browseFailureMessage } from "./browseFailureModel";
import { defaultRow, stepSelection, EMPTY_OMNIBAR, omnibarRows, type OmnibarContext, type OmnibarRow } from "./omnibar";
import { firstProject, homePath, mostRecentProject, projectLabel } from "./sessionList";
import { useT } from "./i18n";
import { isStartableProject, rememberedStartedProject } from "./newtab/startedProject";
import { useNoEntryMotion } from "./newtab/noEntryMotion";
import { usePasteAnywhere } from "./composer/pasteAnywhere";
import { newTabStart, useNewTabChipModel } from "./newtab/chipDefaults";
import type { ComposerAttachment } from "./attachments";
import { AttachmentStrip } from "./composer/attachmentIntake";
import { backspacedAttachment, useAttachmentIntake, useSendWhenAttached } from "./composer/attachmentIntakeModel";
import { reordered } from "./composer/stripReorder";
import { DropOverlay } from "./composer/DropOverlay";
import { useHarnessesListed } from "./catalog";
import { customizeMessage } from "./customizeCommand";
import { useNewTabCommand, type NewTabCommandActions } from "./newtab/useNewTabCommand";
import { reportInputReadyWhenFocused } from "./newtab/inputReady";
import {
  TAB_KINDS,
  type TabKind,
  type NewTabChat,
  FOCUS_LOCATION_EVENT,
  NEW_TAB_LABELS,
  prefixedEdit,
  cycleKind,
  recentSessions,
} from "./newTabModel";

function escapedLiteral(value: string): string {
  return value.replace(/[!-/:-@[-`{-~]/g, "\\$&").replace(/\r\n?|\n/g, "\\\n");
}

/// The next kind for Tab (or Shift+Tab with `step` -1), wrapping.
type KindSwitchDirection = "next" | "previous";

/// The newest sessions first, the ones waiting on the user ahead of them.
type Props = NewTabCommandActions & {
  snapshot: AcpmuxSnapshot;
  /// Each kind's shortcut as the host shows it ("⌃⇧⌘T"); a kind without one shows none.
  hotkeys?: Partial<Record<TabKind, string>>;
  /// The kind selected when the page opens.
  initialKind?: TabKind;
  /// The folder the new tab starts in (the pane's terminal cwd).
  cwd?: string;
  /// The app's copy of the project of the chat the person last picked and started (this run's own
  /// copy wins): the project a tab with no folder of its own starts on.
  startedProject?: string;
  /// This Mac's home folder; unset on a page of another machine (NewTabPageMachine), which never
  /// starts in this Mac's started or recent project.
  home?: string;
  /// The host's project folders (`project.list`): a started or recent project it no longer lists
  /// (removed, deleted) is never the start. Absent or empty is not loaded yet, so every folder
  /// counts; `null` (the host answered with no project), none does.
  knownProjects?: readonly string[] | null;
  /// The machine it runs on (the handshake's `machineName`); "This Mac" when absent.
  host?: string;
  inputToken?: string;
  onInputReady?(token: string): void;
  /// The agent's composer chips (model, mode), shown under the field for Agent, with the page's folder.
  chips?: React.ComponentType<{ snapshot: AcpmuxSnapshot; cwd?: string }>;
  /// The agent the host remembers (the handshake's `newTab.lastAgent`): Agent's harness before a pick.
  lastAgent?: string;
  /// Open tabs, workspaces, folders, commands and history the bar suggests.
  omnibar?: OmnibarContext;
  /// The current tab's URL or folder: in the field and selected when the page opens,
  /// so typing replaces it.
  location?: string;
  /// Recent projects are offered inline before Browse is needed.
  projects?: Project[];
  /// Make the tab `kind`: run `text` (in `cwd`), open it, or ask it. A promise that rejects is a
  /// refused open: the page says so under the field and keeps what was typed.
  onSubmit(
    kind: TabKind,
    text: string,
    cwd?: string,
    attachments?: ComposerAttachment[],
    chat?: NewTabChat,
  ): void | Promise<unknown>;
  /// Go to an open tab or workspace instead of opening a duplicate.
  onJump?(target: "tab" | "workspace", id: string): void;
  onOpenSession(sessionId: string): void;
  onShowAll(): void;
  onEditShortcut?(kind: TabKind): void;
  /// Choose Folder…: the host's folder panel; resolves to the picked folder.
  onBrowseProject?(request?: BrowseRequest): Promise<BrowseResult>;
  /// The page goes with an unsent Agent draft (a typed prompt, staged attachments): handed over so
  /// the chat view that replaces it keeps it (newtab/NewTabScreen.tsx `onLeaveDraft`).
  onLeaveDraft?(text: string, attachments: ComposerAttachment[]): void;
  /// The chat view's composer stood in for this page while the host failed before its handshake:
  /// what was typed there, taken once as the page's own draft when the page comes back.
  takeDraft?(): { text: string; attachments: ComposerAttachment[] } | undefined;
  /// The field's text as typed, after each edit (for a draft it was handed: what a pick leaves again).
  onFieldEdit?(text: string): void;
  now?: number;
};

/// A new tab before it is anything: one field, a Terminal | Browser | Agent switch that
/// Tab cycles, each option with its own shortcut, and the recent sessions below. Enter
/// makes the tab that kind: a terminal running the command, a page, or a chat.
export function NewTabPage({
  snapshot,
  hotkeys = {},
  initialKind = "agent",
  cwd,
  startedProject,
  home,
  knownProjects,
  host,
  chips: Chips,
  lastAgent,
  omnibar = EMPTY_OMNIBAR,
  location,
  projects = [],
  onSubmit,
  onCmuxCommand,
  onImportFile,
  importError,
  importSandboxed,
  onJump,
  onOpenSession,
  onShowAll,
  onEditShortcut,
  onBrowseProject,
  inputToken,
  onInputReady,
  onLeaveDraft,
  takeDraft,
  onFieldEdit,
}: Props) {
  const t = useT();
  const { plainFooter, spellChecking } = useComposerSettings();
  // The classic template is a New Tab page too: what it opens (the project chooser, its menus)
  // appears at once; exits keep their fades (newtab/noEntryMotion.ts).
  useNoEntryMotion();
  const [carried] = useState(() => takeDraft?.());
  // A draft the chat view's composer held is a prompt: the page comes back on Agent with it.
  const [kind, setKind] = useState<TabKind>(carried ? "agent" : initialKind);
  // The field is reused when the kind changes. A short directional handoff gives the new
  // placeholder and context a visible swipe without moving the composer or stealing its focus.
  const [kindSwitch, setKindSwitch] = useState<KindSwitchDirection>();
  const kindSwitchTimer = useRef<number | undefined>(undefined);
  // A tab with no project of its own (none, `~`, a private agent-home folder) on this Mac starts on
  // the project of the chat the person last picked and started (Leo 2026-10-21,
  // newtab/startedProject.ts), else the newest chat's, each only while the host still lists it; a
  // page on another machine (no `home`) never on this Mac's. A pick replaces it.
  const [picked, setProjectCwd] = useState<string | undefined>(undefined);
  const [browseError, setBrowseError] = useState<string>();
  const browseRequest = useRef(0);
  const browsePending = useRef(false);
  useEffect(
    () => () => {
      browseRequest.current += 1;
    },
    [],
  );
  const pickProject = (path: string) => {
    browseRequest.current += 1;
    setBrowseError(undefined);
    setProjectCwd(path);
  };
  const browseProject = async (request?: BrowseRequest): Promise<BrowseResult> => {
    if (browsePending.current) return BROWSE_BUSY;
    browsePending.current = true;
    // The Add Project dialog owns its result and errors until it commits the choice.
    try {
      if (request?.deferPick) return (await onBrowseProject?.(request)) ?? undefined;
      const id = ++browseRequest.current;
      setBrowseError(undefined);
      try {
        const path = await onBrowseProject?.(request);
        if (browseRequest.current === id && typeof path === "string" && path.length > 0) setProjectCwd(path);
        return path;
      } catch (error) {
        if (browseRequest.current === id) setBrowseError(browseFailureMessage(error));
        return undefined;
      }
    } finally {
      browsePending.current = false;
    }
  };
  const [started] = useState(() => (home ? (rememberedStartedProject() ?? startedProject) : undefined));
  const projectCwd =
    picked ??
    (isStartableProject(cwd) || !home
      ? cwd
      : (firstProject(started ? [started.replace(/(.)\/+$/, "$1")] : [], home, knownProjects) ??
        mostRecentProject(snapshot.sessions, home, knownProjects) ??
        cwd));
  // Where the chips' picks start the chat: the project, never the tab's inherited `~` or agent-home
  // folder by itself (cmux#40938: a Codex pick then started in the home folder, which the pane
  // refuses). None: the host starts the chat in its own start folder. A terminal still opens in
  // the tab's folder (`projectCwd`).
  const chatCwd = projectCwd === cwd && !isStartableProject(cwd) ? undefined : projectCwd;
  // Agent's harness and model before a pick, as the New Tab screen reads them (newTabStart): the
  // chips pick on this snapshot, and Return starts the chat on the same harness and model.
  const remembered = useLastPick(projectCwd);
  const harnessesListed = useHarnessesListed();
  const { harness, snapshot: chipSnapshot } = useMemo(
    () => newTabStart(snapshot, snapshot.catalog, lastAgent, projectCwd, remembered, harnessesListed),
    [snapshot, lastAgent, projectCwd, remembered, harnessesListed],
  );
  const chipModel = useNewTabChipModel(chipSnapshot);
  // The field is the chat composer's prompt editor (MarkdownField), as on the New Tab screen
  // (newtab/NewTabScreen.tsx): one composer everywhere (leo-workspace design/new-tab.md). Its value is
  // Markdown; a host-provided location is literal text (paths and URLs can hold `_`, `*` or `[`), so
  // it goes in escaped. A carried composer draft is already Markdown, attachment tokens included.
  const field = useRef<MarkdownFieldHandle | null>(null);
  const [fieldReady, setFieldReady] = useState(false);
  const fieldElement = () => field.current?.element() ?? null;
  const untouchedText = useRef(escapedLiteral(location ?? ""));
  const [text, setText] = useState(carried?.text || untouchedText.current);
  // What was typed, as the agent, a terminal or an address bar gets it: the characters themselves,
  // never the field's Markdown escaping (the screen's `typed`).
  const typed = useMemo(
    () =>
      fieldReady ? (field.current?.agentText(text) ?? text) : text === untouchedText.current ? (location ?? "") : text,
    [text, fieldReady, location],
  );
  /// The last open was refused (the host made no tab): a note under the field until the next edit,
  /// saying which kind did not open, with Retry (the same open again) and the host's words under Details.
  const [openFailed, setOpenFailed] = useState<{ kind: TabKind; detail: string; retry: () => void }>();
  const attachmentRef = useRef<ComposerAttachment[]>([]);
  const make = (next: TabKind, value: string, folder?: string) => {
    setOpenFailed(undefined);
    const attachments = next === "agent" ? attachmentRef.current : [];
    const chat = next === "agent" && harness ? { harness, ...(chipModel ? { model: chipModel } : {}) } : undefined;
    if (next === "agent" && command.intercept(value, harness, attachments.length)) return;
    // `/customize …` goes as the ask it stands for (customizeCommand.ts). Here, the one place every
    // way of starting a chat passes: Enter on the field, Enter on the Ask row, a click on that row.
    const sent = next === "agent" ? (customizeMessage(value.trim()) ?? value) : value;
    const result = onSubmit(next, sent, folder, attachments.length ? attachments : undefined, chat);
    // The suggestions float over the note: they close until the next edit, so it shows.
    if (result)
      void result.catch((error: unknown) => {
        const detail = error instanceof Error ? error.message : typeof error === "string" ? error : "";
        setOpenFailed({ kind: next, detail: detail.trim(), retry: () => make(next, value, folder) });
        setDismissed(queryRef.current);
      });
  };
  // The location stays a suggestion until edited: the rows are the empty bar's.
  const [touched, setTouched] = useState(Boolean(carried?.text));
  const query = touched ? typed : "";
  const [selected, setSelected] = useState(-1);
  // The field was wholly selected before this edit, so a typed prefix starts it over.
  const replacing = useRef(false);
  const list = useRef<HTMLDivElement>(null);
  // With no room under the field for every row, the rows go past the window's edge (cx-6k6cg).
  // A dismiss there (another app, a resize) hides the rows until the query changes; the text stays.
  const [dismissed, setDismissed] = useState<string>();
  const listEdges = useScrollEdges();
  const escape = useEscapingList("bottom", 10, () => setDismissed(queryRef.current));
  const attachList = useCallback(
    (node: HTMLDivElement | null) => {
      list.current = node;
      listEdges(node);
      escape?.(node);
    },
    [escape, listEdges],
  );
  // The kind a prefix switched from, so Backspace in the empty field switches back.
  const [beforePrefix, setBeforePrefix] = useState<TabKind>();
  const {
    attachments,
    setAttachments,
    pending,
    originalFailures,
    unsettled,
    cancel,
    retry,
    attachError,
    drop,
    dropLanded,
  } = useAttachmentIntake({
    allowImages: snapshot.summary?.promptCapabilities?.image !== false,
    pasteTarget: (target) => (kind === "agent" && fieldElement()?.contains(target) ? { uploads: false } : undefined),
    dropZone: () => fieldElement()?.closest(".acpmux-newtab") ?? null,
  });
  const holdForAttachments = useSendWhenAttached(unsettled);
  const command = useNewTabCommand(
    text,
    setText,
    { onCmuxCommand, onImportFile, importError, ...(importSandboxed ? { importSandboxed } : {}) },
    {
      attachments,
      setAttachments,
      pending,
      cancel,
      cancelHeldSend: holdForAttachments.cancel,
    },
  );
  attachmentRef.current = attachments;
  useEffect(() => {
    if (carried?.attachments.length) setAttachments(carried.attachments);
  }, [carried, setAttachments]);
  // The Agent draft as it is now, for `onLeaveDraft` when the page goes (a terminal command or an
  // address has no chat composer to go to).
  const leaving = useRef({ text, attachments, typed: false, kind, onLeaveDraft });
  leaving.current = { text, attachments, typed: text !== untouchedText.current, kind, onLeaveDraft };
  useEffect(
    () => () => {
      const draft = leaving.current;
      if (draft.kind !== "agent") return;
      if ((draft.typed && draft.text.trim()) || draft.attachments.length)
        draft.onLeaveDraft?.(draft.text, draft.attachments);
    },
    [],
  );
  // WEB-SWAP: a web update's reload would lose what this page holds only in its state: a typed
  // query (the location comes back with the page), staged attachments, and a kind or folder picked
  // (pages/shared/webSwap.ts).
  useWebSwapHold(
    text !== untouchedText.current
      ? "newtab.draft"
      : attachments.length || pending.length
        ? "newtab.attachments"
        : kind !== initialKind || picked !== undefined
          ? "newtab.choice"
          : null,
  );
  const [dropHost, setDropHost] = useState<Element | null>(null);
  useEffect(() => {
    const element = field.current?.element();
    setDropHost(element ? (element.closest(".acpmux-newtab") ?? element.ownerDocument.body) : null);
  }, [fieldReady]);
  // The input card, which a file drag rings (composer/DropOverlay.tsx).
  const dropLandingTarget = useCallback(() => field.current?.element()?.closest(".acpmux-newtab-box") ?? null, []);
  // Cmd-V anywhere on the page outside a text field (a row, a card, the empty page) goes into the
  // field, caret at the end, as in a chat (composer/pasteAnywhere.ts; Leo 2026-10-22: "cmd v anywhere
  // in chat should put it in chat").
  usePasteAnywhere(() => {
    const input = field.current;
    if (!input) return false;
    input.focus();
    input.setCaret(input.plainText().length);
    return true;
  });
  const composing = useRef(false);
  const recent = useMemo(() => recentSessions(snapshot.sessions), [snapshot.sessions]);
  // The suggestions float over the page under the field (cx-6k6cg), so they show only while the
  // field has the keyboard and something is typed: at rest nothing covers the page below.
  const [focused, setFocused] = useState(false);
  const queryRef = useRef(query);
  queryRef.current = query;
  const open = focused && query.trim() !== "" && query !== dismissed;
  const suggestions = useMemo(
    () =>
      omnibarRows(query, kind, {
        ...omnibar,
        sessions: recent.map((session) => ({
          sessionId: session.sessionId,
          title: session.displayTitle ?? session.sessionId,
          ...(session.harness ? { harness: session.harness } : {}),
          detail: projectLabel(session.cwd),
        })),
      }),
    [query, kind, omnibar, recent],
  );
  const rows = useMemo(() => (open ? suggestions : []), [open, suggestions]);
  useEffect(() => setSelected(defaultRow(rows, kind, query)), [rows, kind, query]);
  useEffect(() => {
    // Rows past the window's edge draw in the host; the invisible list never scrolls the page.
    if (list.current?.hasAttribute("data-escaped")) return;
    list.current?.querySelector<HTMLElement>(`#acpmux-omni-${selected}`)?.scrollIntoView?.({ block: "nearest" });
  }, [selected]);
  // A pane without a known folder names none rather than showing "No folder".
  const selectedProject = projectCwd ? projectLabel(projectCwd) : undefined;
  const folder = projectCwd ? projectLabel(projectCwd) : "";
  const agent = agentDisplayName(harness ?? "agent");
  const placeholder = NEW_TAB_LABELS.placeholder[kind](t, kind === "agent" ? agent : folder);

  const changeKind = (next: TabKind) => {
    if (next === kind) return;
    const direction: KindSwitchDirection = cycleKind(kind) === next ? "next" : "previous";
    const view = fieldElement()?.ownerDocument.defaultView ?? window;
    if (kindSwitchTimer.current !== undefined) view?.clearTimeout(kindSwitchTimer.current);
    // Clear first, then re-arm on the next frame. Consecutive forward switches (Tab) therefore
    // restart the animation even though the direction stays the same.
    setKindSwitch(undefined);
    setKind(next);
    view?.requestAnimationFrame(() => {
      setKindSwitch(direction);
      kindSwitchTimer.current = view.setTimeout(() => setKindSwitch(undefined), 220);
    });
  };

  useEffect(
    () => () => {
      if (kindSwitchTimer.current !== undefined) window.clearTimeout(kindSwitchTimer.current);
    },
    [],
  );

  // The field takes the keyboard when the page appears, as a browser's new tab does, and
  // again on Cmd-L (the host's FOCUS_LOCATION_EVENT), wherever focus moved on the page; only
  // then, so an update (the App hands a new callback on each render) or a click into the field
  // never moves its caret or restarts its blink.
  // The editor mounts a moment after the field (`fieldReady`): the first focus waits for it.
  const inputReady = useRef(onInputReady);
  inputReady.current = onInputReady;
  const inputReadyReported = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    if (!fieldReady) return;
    const focus = () => {
      const input = field.current;
      if (!input) return;
      input.focus();
      // AllSelection in an empty document selects the root, outside its typing paragraph (the
      // screen's focus does the same).
      if (input.plainText().trim()) input.selectAll();
      else input.setCaret(0);
      // A page shown in a window that is not key yet gets no focus event until it is.
      setFocused(input.focused());
    };
    focus();
    const host = fieldElement()?.ownerDocument.defaultView;
    // The app replays the keys typed after Cmd-T at this readiness: it waits for the page's focus.
    let cancelReady = () => {};
    if (inputToken && inputReadyReported.current !== inputToken) {
      cancelReady = reportInputReadyWhenFocused(host, () => {
        inputReadyReported.current = inputToken;
        inputReady.current?.(inputToken);
      });
    }
    host?.addEventListener(FOCUS_LOCATION_EVENT, focus);
    return () => {
      cancelReady();
      host?.removeEventListener(FOCUS_LOCATION_EVENT, focus);
    };
  }, [inputToken, fieldReady]);
  const choose = (next: TabKind) => {
    changeKind(next);
    setBeforePrefix(undefined);
    field.current?.focus();
  };
  const activate = (row: OmnibarRow) => {
    switch (row.type) {
      case "tab":
      case "workspace":
        return onJump?.(row.type, row.id);
      case "session":
        return onOpenSession(row.id);
      case "folder":
        return make("terminal", "", row.path);
      case "command":
        return make("terminal", row.command, projectCwd);
      case "history":
        return make("browser", row.url);
      case "run":
        return make("terminal", row.text, projectCwd);
      case "open":
        return make("browser", row.text);
      case "ask":
        return make("agent", row.text, projectCwd);
    }
  };
  // The row is the field's text area (the I-beam shows over all of it): a press beside the
  // field, or on its padding above and below the text, focuses it; the editable text and the
  // kind switch keep their own presses. Pointer only, so the row is presentation: keys reach the
  // field itself.
  const focusFromRow = (event: React.MouseEvent<HTMLDivElement>) => {
    const target = event.target as Element;
    const editable = fieldElement()?.querySelector('[contenteditable="true"]');
    if (editable?.contains(target) || target.closest("fieldset, button")) return;
    event.preventDefault();
    field.current?.focus();
  };
  const submitNow = useRef<() => void>(() => {});
  const submit = (event?: React.FormEvent) => {
    event?.preventDefault();
    if (kind === "agent" && command.intercept(query.trim(), harness, attachments.length, true)) return;
    if (holdForAttachments(() => submitNow.current())) return;
    submitNow.current();
  };
  submitNow.current = () => {
    if (kind === "agent" && command.intercept(query.trim(), harness, attachments.length)) return;
    const row = rows[selected];
    if (row) return activate(row);
    if (kind === "browser" && !query.trim()) return;
    make(kind, query.trim(), kind === "browser" ? undefined : projectCwd);
  };
  const keyDown = (event: KeyboardEvent) => {
    if (composing.current || event.isComposing || event.keyCode === 229) return;
    const input = field.current?.text() ?? { value: typed, selectionStart: typed.length, selectionEnd: typed.length };
    replacing.current = input.value !== "" && input.selectionStart === 0 && input.selectionEnd === input.value.length;
    // A prompt of several lines, wrapped ones too, keeps ↑ and ↓ for its caret while there is a line
    // to move to (the New Tab screen's rule, newtab/NewTabScreen.tsx `movesCaretInPrompt`); past it
    // they step the rows.
    const plainArrow = !event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;
    const onEdge = (direction: "up" | "down") => field.current?.caretOnEdgeLine(direction) ?? true;
    const movesCaret =
      plainArrow &&
      (event.key === "ArrowUp"
        ? input.value.slice(0, input.selectionStart).includes("\n") || !onEdge("up")
        : event.key === "ArrowDown" && (input.value.slice(input.selectionEnd).includes("\n") || !onEdge("down")));
    if ((event.key === "ArrowDown" || event.key === "ArrowUp") && rows.length && !movesCaret) {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      setSelected((current) => stepSelection(current, step, rows.length));
    } else if (event.key === "Escape" && typed) {
      event.preventDefault();
      setText("");
      setTouched(true);
    } else if (event.key === "Tab" && !event.altKey && !event.metaKey && !event.ctrlKey) {
      event.preventDefault();
      setBeforePrefix(undefined);
      changeKind(cycleKind(kind, event.shiftKey ? -1 : 1));
    } else if (event.key === "Backspace" && typed === "" && beforePrefix) {
      event.preventDefault();
      changeKind(beforePrefix);
      setBeforePrefix(undefined);
    } else {
      // Backspace at the field's start takes back the last chip (backspacedAttachment).
      const backspaced = backspacedAttachment(event, field.current?.atStart() ?? false, attachments);
      if (!backspaced) return;
      event.preventDefault();
      setAttachments((current) => current.filter((item) => item.id !== backspaced.id));
    }
  };
  const prefixReset = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    const value = prefixReset.current;
    if (value === undefined) return;
    prefixReset.current = undefined;
    if (field.current?.value() !== value) field.current?.reset(value);
  }, [kind]);
  const edit = (next: string) => {
    // The editor canonicalizes the location's escaping as it mounts: still the untouched location,
    // not a typed draft, a reason to show suggestions or a web swap to hold.
    if (!fieldReady && field.current?.agentText(next) === (location ?? "")) {
      untouchedText.current = next;
      setText(next);
      return;
    }
    setTouched(true);
    setOpenFailed(undefined);
    const plain = field.current?.agentText(next) ?? next;
    onFieldEdit?.(plain);
    const prefixed = composing.current ? undefined : prefixedEdit(replacing.current ? "" : typed, plain);
    replacing.current = false;
    if (prefixed && prefixed.kind !== kind) {
      setBeforePrefix(kind);
      changeKind(prefixed.kind);
      // The prefix is consumed: the field holds what follows it, as typed. The editor already holds
      // the prefix, and the value may not change (a lone `!`), so it is reset after this edit.
      prefixReset.current = escapedLiteral(prefixed.text);
      setText(prefixReset.current);
      return;
    }
    setText(next);
  };
  // The composer's look (composerLook.ts; the page's first two dots, newtab/PageDots.tsx): both lay
  // the row under the field out the same; Codex's names Full access in the accent (composerLook.css).
  const look = useComposerLook();
  const foot = useRef<HTMLDivElement>(null);
  useRowFit(foot, `${kind}:${plainFooter}:${look}`);

  return (
    <div className="acpmux-newtab" data-kind={kind} data-composer-look={look === "codex" ? "codex" : undefined}>
      {/* The suggestions float under the field (cx-6k6cg): opening them moves nothing below. */}
      <div className="acpmux-newtab-anchor">
        <form className="acpmux-newtab-box" onSubmit={submit}>
          <div
            className="acpmux-newtab-row"
            data-kind-switch={kindSwitch}
            role="presentation"
            onMouseDown={focusFromRow}
            onFocus={(event) => {
              if (fieldElement()?.contains(event.target)) setFocused(true);
            }}
            onBlur={(event) => {
              if (
                fieldElement()?.contains(event.target) &&
                !fieldElement()?.contains(event.relatedTarget as Node | null)
              )
                setFocused(false);
            }}
          >
            <KindIcon kind={kind} />
            {/* The chat composer's prompt editor (MarkdownField), as the New Tab screen draws it: a long
                prompt wraps and grows to its cap, then scrolls; Return opens; Shift-Return adds a line.
                Commands and addresses keep their characters (literal). */}
            <MarkdownField
              ref={field}
              className="acpmux-newtab-field"
              value={text}
              placeholder={placeholder}
              multiline
              plainInput
              literal={kind !== "agent"}
              onReady={() => setFieldReady(true)}
              onChange={(value) => edit(value)}
              onKeyDown={keyDown}
              onCompositionChange={(value) => {
                composing.current = value;
              }}
              onSubmit={() => submit()}
              attributes={{
                [WEB_SWAP_KEPT_TEXT]: "",
                "data-focus-ring": "none",
                "aria-label": placeholder,
                "aria-controls": "acpmux-omni",
                "aria-activedescendant": selected >= 0 ? `acpmux-omni-${selected}` : undefined,
                spellcheck: spellChecking && kind === "agent" ? "true" : "false",
                autocapitalize: "off",
                autocorrect: "off",
              }}
            />
            <fieldset className="acpmux-newtab-switch" aria-label={t(NEW_TAB_LABELS.switchLabel)}>
              {TAB_KINDS.map((option) => (
                <button
                  key={option}
                  type="button"
                  aria-pressed={option === kind}
                  tabIndex={-1}
                  className={option === kind ? "acpmux-newtab-kind is-selected" : "acpmux-newtab-kind"}
                  // tooltip-allow: the kind's keyboard shortcut
                  title={
                    hotkeys[option]
                      ? t(NEW_TAB_LABELS.editShortcut, {
                          kind: t(NEW_TAB_LABELS.kinds[option]),
                          keys: hotkeys[option]!,
                        })
                      : undefined
                  }
                  onClick={() => choose(option)}
                  onContextMenu={(event) => {
                    if (!onEditShortcut) return;
                    event.preventDefault();
                    onEditShortcut(option);
                  }}
                >
                  <KindIcon kind={option} />
                  <span>{t(NEW_TAB_LABELS.kinds[option])}</span>
                  {hotkeys[option] && <kbd>{hotkeys[option]}</kbd>}
                </button>
              ))}
            </fieldset>
          </div>
          {command.input}
          <AttachmentStrip
            attachments={attachments}
            pending={pending}
            {...(command.error || attachError ? { error: command.error ?? attachError } : {})}
            codex={false}
            onRemove={(id) => {
              setAttachments((current) => current.filter((item) => item.id !== id));
              field.current?.focus();
            }}
            onCancel={(id) => {
              cancel(id);
              field.current?.focus();
            }}
            onRetry={retry}
            originalFailures={originalFailures}
            onReorder={(id, index) => setAttachments((current) => reordered(current, id, index))}
          />
          {dropHost && (
            <DropOverlay state={drop} onLanded={dropLanded} container={dropHost} landingTarget={dropLandingTarget} />
          )}
          <div className="acpmux-newtab-under" data-kind-switch={kindSwitch}>
            <span className="acpmux-newtab-context">
              {kind !== "browser" && (
                <ProjectChooser
                  projects={projects}
                  current={projectCwd}
                  currentLabel={selectedProject}
                  icon={<FolderIcon />}
                  onPick={pickProject}
                  onBrowse={onBrowseProject && browseProject}
                />
              )}
              {kind === "terminal" && (
                <span className="acpmux-newtab-chip">
                  <LaptopIcon />
                  {host ?? t(NEW_TAB_LABELS.thisMac)}
                </span>
              )}
              {kind === "agent" && (
                <span className="acpmux-newtab-chip">
                  <KindIcon kind="agent" />
                  {agent}
                </span>
              )}
            </span>
            <button
              type="submit"
              className={`acpmux-send${query.trim() || kind !== "browser" ? " acpmux-send-ready" : ""}`}
              aria-label={t(NEW_TAB_LABELS.open)}
              title={`${t(NEW_TAB_LABELS.open)} ↵`}
            >
              <ArrowUpIcon />
            </button>
          </div>
        </form>
        {kind === "agent" && Chips && (
          <div className="acpmux-newtab-foot">
            <ComposerFoot ref={foot} plain={plainFooter}>
              <Chips snapshot={chipSnapshot} {...(chatCwd ? { cwd: chatCwd } : {})} />
            </ComposerFoot>
          </div>
        )}
        {rows.length > 0 && (
          <div
            ref={attachList}
            className="acpmux-omni ui-popup ui-glass ui-scroll-edge-fade"
            id="acpmux-omni"
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="listbox"
            aria-label={t(NEW_TAB_LABELS.suggestions)}
          >
            {/* Virtual focus, as the composer's slash menu: the field keeps focus and names the row. */}
            {rows.map((row, index) => (
              <div
                key={rowKey(row)}
                id={`acpmux-omni-${index}`}
                // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                role="option"
                tabIndex={-1}
                aria-selected={index === selected}
                className={index === selected ? "acpmux-omni-row is-selected" : "acpmux-omni-row"}
                // Hover only lights the row (styles.css); Return stays the keyboard's row, as on
                // the New Tab screen (newtab/NewTabScreen.tsx). A press still runs the row.
                onMouseDown={(event) => {
                  event.preventDefault();
                  activate(row);
                }}
              >
                <RowIcon row={row} agent={snapshot.summary?.harness ?? snapshot.catalog[0]?.id} />
                <span className="acpmux-omni-text">
                  <span className="acpmux-omni-title">
                    {row.type === "ask" && <b>{t(NEW_TAB_LABELS.ask, { agent })}: </b>}
                    {rowTitle(row)}
                  </span>{" "}
                  {rowDetail(row) && <span className="acpmux-omni-detail">{rowDetail(row)}</span>}
                </span>
                <span className="acpmux-omni-action" data-popup-skip>
                  {row.type === "ask" ? t(NEW_TAB_LABELS.ask, { agent }) : t(NEW_TAB_LABELS.rows[row.type])}
                  {index === selected && <kbd>↵</kbd>}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>
      {browseError && (
        <BrowseFailure
          error={browseError}
          onRetry={() => void browseProject()}
          onDismiss={() => setBrowseError(undefined)}
        />
      )}
      {openFailed && (
        <div className="acpmux-newtab-failed" role="alert">
          <p className="acpmux-newtab-failed-message">{t(NEW_TAB_LABELS.openFailedKind[openFailed.kind])}</p>
          <button type="button" className="acpmux-newtab-failed-retry ui-ghost" onClick={openFailed.retry}>
            {t(NEW_TAB_LABELS.openRetry)}
          </button>
          {openFailed.detail && <ErrorDetails text={openFailed.detail} className="acpmux-newtab-failed-details" />}
        </div>
      )}
      <div className="acpmux-newtab-actions ui-ghost-row">
        <button type="button" className="acpmux-newtab-all ui-ghost" onClick={onShowAll}>
          <span>{t(NEW_TAB_LABELS.allSessions)}</span>
          <span className="ui-ghost-icon" aria-hidden="true">
            <ChevronRight />
          </span>
        </button>
      </div>
    </div>
  );
}

function rowKey(row: OmnibarRow): string {
  switch (row.type) {
    case "tab":
    case "workspace":
    case "session":
      return `${row.type}:${row.id}`;
    case "folder":
      return `folder:${row.path}`;
    case "command":
      return `command:${row.command}`;
    case "history":
      return `history:${row.url}`;
    // Rows that are the typed text itself (Run, Open, Ask) are a new row for each query, as a command
    // row is: kept by their type alone, the last row (Ask) slid up whenever the matches above it fell
    // away (`g` drew six rows, `gi` two), which counts as a layout shift on the frames that drew both
    // (cmux#35744).
    case "run":
    case "open":
    case "ask":
      return `${row.type}:${row.text}`;
  }
}

function rowTitle(row: OmnibarRow): string {
  switch (row.type) {
    case "tab":
    case "workspace":
    case "session":
      return row.title;
    case "folder":
      return projectLabel(row.path);
    case "command":
      return row.command;
    case "history":
      return row.title || row.url;
    default:
      return row.text;
  }
}

function rowDetail(row: OmnibarRow): string | undefined {
  switch (row.type) {
    case "tab":
    case "workspace":
    case "session":
      return row.detail;
    case "folder":
      return homePath(row.path);
    case "history":
      return row.title ? row.url.replace(/^https?:\/\//, "") : undefined;
    default:
      return undefined;
  }
}

function RowIcon({ row, agent }: { row: OmnibarRow; agent?: string }) {
  switch (row.type) {
    case "tab":
      return row.icon ? <Favicon src={row.icon} /> : <KindIcon kind={row.kind} />;
    case "workspace":
      return <WorkspaceIcon />;
    case "session":
      return <AgentMark harness={row.harness} />;
    case "folder":
      return <FolderIcon />;
    case "command":
    case "run":
      return <KindIcon kind="terminal" />;
    case "history":
      return row.icon ? <Favicon src={row.icon} /> : <ClockIcon />;
    case "open":
      return <KindIcon kind="browser" />;
    case "ask":
      return <AgentMark harness={agent} />;
  }
}

/// A page's favicon (cx-d0d.8), drawn as is at the row icons' size.
function Favicon({ src }: { src: string }) {
  return <img className="acpmux-icon acpmux-favicon" src={src} alt="" width={16} height={16} draggable={false} />;
}

/// The agent's brand mark (design/agent-icons) or its harness's own icon, so a session's row says
/// which agent it is at a glance; an agent without either draws the generic agent glyph.
export function AgentMark({ harness }: { harness?: string }) {
  return <BrandMark agent={harness} size={16} fallback={<KindIcon kind="agent" />} />;
}

// 16px stroke icons in currentColor, matching ComposerPickers.
function Icon({ children }: { children: React.ReactNode }) {
  return (
    <svg
      className="acpmux-icon"
      width={16}
      height={16}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

export function KindIcon({ kind }: { kind: TabKind }) {
  switch (kind) {
    case "terminal":
      return (
        <Icon>
          <rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2" />
          <path d="m4.6 6.2 2 1.8-2 1.8M8.4 10h3" />
        </Icon>
      );
    case "browser":
      return (
        <Icon>
          <circle cx="8" cy="8" r="6.1" />
          <path d="M1.9 8h12.2M8 1.9c1.7 1.7 2.5 3.7 2.5 6.1S9.7 12.4 8 14.1C6.3 12.4 5.5 10.4 5.5 8S6.3 3.6 8 1.9Z" />
        </Icon>
      );
    case "agent":
      return (
        <Icon>
          <path d="M8 1.9c.4 2.9 1.6 4.1 4.6 4.6-3 .5-4.2 1.7-4.6 4.6-.4-2.9-1.6-4.1-4.6-4.6 3-.5 4.2-1.7 4.6-4.6Z" />
          <path d="M12.4 10.4c.15 1.1.6 1.55 1.7 1.7-1.1.15-1.55.6-1.7 1.7-.15-1.1-.6-1.55-1.7-1.7 1.1-.15 1.55-.6 1.7-1.7Z" />
        </Icon>
      );
  }
}

/// A folder glyph (the project picker on both New Tab designs).
export const FolderIcon = () => (
  <Icon>
    <path d="M1.9 4.6c0-.8.6-1.4 1.4-1.4h2.6l1.5 1.6h5.3c.8 0 1.4.6 1.4 1.4v5.6c0 .8-.6 1.4-1.4 1.4H3.3c-.8 0-1.4-.6-1.4-1.4Z" />
  </Icon>
);
const LaptopIcon = () => (
  <Icon>
    <rect x="3" y="3.4" width="10" height="7" rx="1.2" />
    <path d="M1.6 12.6h12.8" />
  </Icon>
);
const WorkspaceIcon = () => (
  <Icon>
    <rect x="2" y="2.6" width="12" height="10.8" rx="2" />
    <path d="M6.2 2.6v10.8" />
  </Icon>
);
const ClockIcon = () => (
  <Icon>
    <circle cx="8" cy="8" r="6.1" />
    <path d="M8 4.6V8l2.3 1.5" />
  </Icon>
);
const ChevronRight = () => (
  <Icon>
    <path d="m6.3 4.6 3.3 3.4-3.3 3.4" />
  </Icon>
);
