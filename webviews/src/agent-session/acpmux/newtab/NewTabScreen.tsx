import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import type { DictationField } from "../dictation";
import { FOCUS_LOCATION_EVENT, type NewTabHost } from "../NewTabPage";
import type { AcpmuxSnapshot } from "../model";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../omnibar";
import { ComposerContext } from "../ComposerContext";
import type { Project } from "../ProjectChooser";
import { isAgentHome, mostRecentProject } from "../sessionList";
import { AllChatsList, type LoadChatsPage } from "./AllChatsList";
import { ChatCards } from "./ChatCards";
import { ClosedList } from "./ClosedList";
import { OpenTabsList } from "./OpenTabsList";
import { type NowPlayingCommand, NowPlayingPlayer } from "./NowPlayingPlayer";
import { ArrowUpIcon } from "../ComposerPickers";
import { newTabStart, useNewTabChipModel } from "./chipDefaults";
import { useLastPick } from "../lastPick";
import { useDeviceChats } from "./deviceChats";
import { useRecentlyClosed } from "./recentlyClosed";
import { initialRecentProject } from "./recentProject";
import {
  canonicalAddress,
  defaultSelection,
  isAddress,
  inlineCompletion,
  needsYouCards,
  recentChatCards,
  screenRows,
  shellEntry,
  shortHost,
  stepSelection,
  type CreateKind,
  type ScreenRow,
} from "./screenModel";
import { RowGlyph } from "./RowGlyph";
import { WidgetCards } from "./WidgetCards";
import { EnvironmentCard, SuggestionsCard } from "./StageCards";
import { useComposerSettings } from "../composerSettings";
import { Icon } from "../icons/Icon";
import { type NewTabTranslate, useNt } from "./strings";
import { screenSections, type ScreenTemplate } from "./templates";
import { type Translate, useT } from "../i18n";
import { ChromeArea } from "../../../ui/HideableChrome";
import { Popover } from "../../../ui/Popover";
import { useEscapingPopup } from "../../../ui/popupHost";
import { usePopupHost } from "../../../ui/UiProvider";
import { UI_ANCHOR_GAP } from "../../../ui/anchor";
import { useComposerChrome } from "../composerChrome";
import { useMenuPressGuard } from "../menuPressGuard";
import { useMinuteClock } from "../clock";

/// What the screen asks the host to do. A prompt stays in the page (the tab becomes the chat).
export type NewTabScreenActions = {
  /// Enter on a prompt: a chat with `harness` in `cwd` (the project picked on the page).
  /// `model`: the one the chip names, so the chat starts on what the page showed.
  /// `noProject`: Do not work in a project was picked, so the chat starts in no project.
  onAsk(harness: string, text: string, cwd?: string, model?: string, noProject?: boolean): void;
  onOpen(url: string): void;
  onSearch(text: string): void;
  /// Enter in shell mode (`!` first): the page becomes a chat in its folder that runs `command`.
  onShell(command: string): void;
  /// `here`: an Open Tabs pick, moved into this page's pane (cx-jfo7).
  onJump(target: "tab" | "workspace" | "here" | "closed", id: string): void;
  onOpenSession(sessionId: string): void;
  /// A device chat card (acpmux chat index, the sidebar's All chats): the host's Open Chat path.
  onOpenChat?(key: string): void;
  /// Open in terminal from an All chats row's right-click menu.
  onOpenChatInTerminal?(key: string): void;
  /// One page of All chats from the host (`chats.page`); without it the page shows no All chats list.
  loadChatsPage?: LoadChatsPage;
  onShowAll(): void;
  onInputReady?(token: string): void;
  /// The first user input reached the page (the host recycles only an untouched page, R81).
  onTouched?(): void;
  /// The machine the page runs on and its chat starts on (the host's name for it), for the
  /// location row's computer.
  machineName?: string;
  /// New terminal / New browser tab (cx-ag5.7): the host replaces this tab with a blank one.
  onCreate?(kind: "terminal" | "browser"): void;
  /// The Now Playing player's controls (`nowPlaying.command`); without it the page shows no player.
  onNowPlaying?(command: NowPlayingCommand): void;
};

/// The agent's model, effort and speed chip (App's composer chips), for the agent and project a
/// prompt would start in.
export type NewTabChips = React.ComponentType<{ snapshot: AcpmuxSnapshot; cwd?: string }>;

type Props = NewTabScreenActions & {
  snapshot: AcpmuxSnapshot;
  omnibar?: OmnibarContext;
  /// The tab the page opened from (its URL or folder): in the field and selected.
  location?: string;
  lastAgent?: string;
  home?: string;
  /// The host's project folders (`project.list` and the page's own list), so a deleted or removed
  /// folder never becomes the start project. Absent, every local chat folder counts.
  knownProjects?: readonly string[];
  /// The workspace's tabs to move here (a split's page, cx-jfo7).
  openTabs?: NewTabHost["openTabs"];
  inputToken?: string;
  now?: number;
  /// The folder the tab inherited: the project picker starts there.
  cwd?: string;
  /// The folder a prompt with no pick starts in (the host's start folder, a private folder in a
  /// fresh workspace); the composer chip names it, not the inherited `cwd` (nxdog91 F0).
  startCwd?: string;
  /// true until the host's handshake answers: `startCwd` is not known yet, so the chip names the
  /// project the tab inherited (the handshake starts its chat there) rather than none.
  startPending?: boolean;
  /// true until this page's daemon connection has listed the chats (`listedSessions`), while no
  /// chat is known: the recent project may still come, so the folder chip holds its place.
  chatsPending?: boolean;
  /// The projects the picker offers (App's newTabProjects).
  projects?: Project[];
  /// The host's folder panel; resolves with the folder picked, if any.
  onBrowseProject?(): Promise<string | undefined>;
  chips?: NewTabChips;
  /// false: the field does not take the keyboard when the screen appears (Cmd-L gave it to the
  /// omnibar); Cmd-L on the page still focuses it when the page shows no omnibar.
  focusField?: boolean;
  /// Which screen template draws the page (newtab/templates.ts); "default" when unset.
  template?: ScreenTemplate;
  /// The widget view (Debug Settings `newTab.widgets`): the Projects and Needs you cards.
  widgets?: boolean;
  /// Buttons before Send, such as the dictation mic (DictationMic).
  accessory?: React.ReactNode;
  /// Why dictation did not run (DictationNotice), under the field.
  notice?: React.ReactNode;
  /// Where the page's dictation writes: the field, while the screen shows.
  dictationField?: React.MutableRefObject<DictationField | null>;
};

/// `/`, `/Users`, a home folder: never a chat's start folder (AgentPaneStartFolders drops them).
function homeOrAbove(cwd: string | undefined): boolean {
  return !cwd || /^\/(?:(?:Users|home)(?:\/[^/]+)?)?\/?$/.test(cwd);
}

/// How long the folder chip holds its place for a daemon that has not listed the chats yet.
const RESERVE_MS = 2_000;

/// The new tab screen, variant B (plans/cmux-next/new-tab.md): the project and model pickers on
/// top, then one field that reads what is typed (`!` a shell command, an address, or a prompt for
/// the picked agent, R86), the rows for addresses and open tabs only when they make sense
/// (cx-e2aa), and the recent chats as cards. A key typed anywhere on the page goes to the field.
export function NewTabScreen(props: Props) {
  const nt = useNt();
  const { snapshot, omnibar = EMPTY_OMNIBAR, location, lastAgent, home, now, inputToken } = props;
  const template = props.template ?? "default";
  const sections = screenSections(template);
  // Claude Code desktop's layout (templates.ts stage): the composer at the foot, the cards over it.
  const stage = sections.stage;
  // The composer's plain footer (#22050, composerSettings.ts): no pill at rest, a wash on hover.
  const { plainFooter } = useComposerSettings();
  const [text, setText] = useState(location ?? "");
  // The location stays a suggestion until edited: no rows for it.
  const [touched, setTouched] = useState(false);
  // The highlighted row; -1 is none (Enter is the prompt's).
  const [selected, setSelected] = useState<number | undefined>(undefined);
  // Whether the highlight was moved by the keyboard (Down, Up, Tab): only then does Tab step it.
  const [keyboardPick, setKeyboardPick] = useState(false);
  /// Shell mode: the field holds a command (its `!` shown as the glyph), Enter runs it in a chat.
  const [shell, setShell] = useState(false);
  const [seeded, setProject] = useState(props.cwd && !isAgentHome(props.cwd) ? props.cwd : undefined);
  // A tab with no project of its own (none, the home folder or a private agent-home folder) and no
  // start folder from the host starts on the most recent project (Leo 2026-10-18), until a pick.
  const [picked, setPicked] = useState(false);
  // Do not work in a project (Leo 2026-10-18): no project, no start folder, until a folder pick.
  const [none, setNone] = useState(false);
  const folderless = !props.cwd || props.cwd === home || isAgentHome(props.cwd);
  const startsRecent = !picked && folderless && !props.startCwd;
  const candidate = useMemo(
    () => (startsRecent ? mostRecentProject(snapshot.sessions, home, props.knownProjects) : undefined),
    [startsRecent, snapshot.sessions, home, props.knownProjects],
  );
  // Decided once, as the page mounts (Leo 2026-10-19: the first frame showed "Choose folder", then
  // flipped to the recent project): the newest in the chats the page already has, else the newest a
  // page of this run heard (newtab/recentProject.ts). A chat updating elsewhere must not move the
  // chip while the user types, so the first one found stays.
  const [latched, setLatched] = useState<string | undefined>(() =>
    startsRecent ? initialRecentProject(snapshot.sessions, home, props.knownProjects) : undefined,
  );
  // Before the host's project list lands, a chat folder counts; once it lands, one it does not
  // list (removed, deleted) gives way to the newest it lists.
  const known = props.knownProjects?.length ? props.knownProjects : undefined;
  if (latched !== undefined && known && !known.some((path) => path.replace(/(.)\/+$/, "$1") === latched))
    setLatched(undefined);
  else if (latched === undefined && candidate !== undefined && (props.knownProjects === undefined || known))
    setLatched(candidate);
  const recent = startsRecent ? (latched ?? candidate) : undefined;
  // Nothing knows the recent project yet (the run's first page, before its daemon lists the chats):
  // the folder chip keeps its place but names nothing, rather than "Choose folder" and then the
  // project. A daemon that has not answered in RESERVE_MS shows the chip as it is.
  const pending = startsRecent && !none && recent === undefined && props.chatsPending === true;
  const [reserveOver, setReserveOver] = useState(false);
  useEffect(() => {
    if (!pending) return;
    const timer = setTimeout(() => setReserveOver(true), RESERVE_MS);
    return () => clearTimeout(timer);
  }, [pending]);
  const projectPending = pending && !reserveOver;
  const project = none ? undefined : (recent ?? seeded);
  const field = useRef<HTMLTextAreaElement>(null);
  const wholeSelection = useRef(false);
  const inlineCaret = useRef<number | undefined>(undefined);
  const composing = useRef(false);
  const inputReported = useRef(false);
  const inputReadyReported = useRef<string | undefined>(undefined);
  // The App hands a new callback on each render; the field must not take the keyboard again for it.
  const onInputReady = useRef(props.onInputReady);
  onInputReady.current = props.onInputReady;
  const focusOnShow = props.focusField !== false;
  const touch = () => {
    if (inputReported.current) return;
    inputReported.current = true;
    props.onTouched?.();
  };
  const agents = useMemo(
    () => snapshot.catalog.map((entry) => ({ id: entry.id, name: entry.name })),
    [snapshot.catalog],
  );
  // A real pick names its folder; else the folder the chat really starts in (screenActions onAsk).
  const chatFolder = none
    ? undefined
    : project && project !== props.cwd
      ? project
      : (props.startCwd ?? project ?? props.cwd);
  // The project chip names the folder a prompt starts in (screenActions onAsk): a real pick, else
  // the host's start folder, as a new chat's hero does; never the home ~ a fresh workspace's tab
  // inherits, nor the private agent-home folder a chat with neither starts in (cx-7fje0, cx-nn3e).
  // Before the host's handshake names the start folder, a tab that inherits a project names that
  // project (the handshake starts its chat there), so the first frame shows it.
  const askFolder = none
    ? undefined
    : project && project !== props.cwd
      ? project
      : (props.startCwd ?? (props.startPending && !folderless && !homeOrAbove(props.cwd) ? props.cwd : undefined));
  // The environment card checks the project the chat starts in: the chip's folder, else the tab's
  // own project (never the home ~ or a private agent-home folder it inherited).
  const envFolder = none ? undefined : (askFolder ?? (props.cwd && !folderless ? props.cwd : undefined));
  // A prompt's chat, in no project when that was the pick.
  const askChat = (agent: string, prompt: string, cwd?: string, model?: string) =>
    none ? props.onAsk(agent, prompt, cwd, model, true) : props.onAsk(agent, prompt, cwd, model);
  // The agent Enter asks and the chip's model (newTabStart): the chip's pick, else the last pick.
  const remembered = useLastPick(chatFolder);
  const { harness, snapshot: chipSnapshot } = useMemo(
    () => newTabStart(snapshot, agents, lastAgent, chatFolder, remembered),
    [snapshot, agents, lastAgent, chatFolder, remembered],
  );
  const chipModel = useNewTabChipModel(chipSnapshot);
  // The Ask row names the agent Return asks and the model on its chip.
  const ask = useMemo(() => {
    const entry = snapshot.catalog.find((agent) => agent.id === harness);
    if (!harness || !entry) return undefined;
    const model = entry.models.find((option) => option.id === chipSnapshot.summary?.model)?.name;
    return { harness, agent: entry.name, ...(model ? { model } : {}) };
  }, [snapshot.catalog, harness, chipSnapshot.summary?.model]);
  // A dismiss (a press outside the composer, Escape, or the host's: another app, a resize) hides
  // the rows until the text changes or the field is pressed; the text stays (Leo 10-13).
  const [dismissed, setDismissed] = useState<string>();
  const textRef = useRef(text);
  textRef.current = text;
  // The create actions the buttons under the field offer, at the end of the rows too.
  const creates = useMemo(
    (): CreateKind[] => [
      ...(props.onCreate ? (["terminal", "browser"] as const) : []),
      ...(harness ? (["chat"] as const) : []),
    ],
    [props.onCreate, harness],
  );
  const suggested = useMemo(
    () => (touched && !shell ? screenRows(text, { omnibar, home, create: creates, ...(ask ? { ask } : {}) }) : []),
    [touched, shell, text, omnibar, home, ask, creates],
  );
  const rows = text !== dismissed ? suggested : [];
  // New tabs or pages from the host can shorten the rows under a highlight.
  const current = selected === undefined ? defaultSelection(rows) : selected < rows.length ? selected : -1;
  const t = useT();
  const chrome = useComposerChrome();
  // A press outside an open chip menu only closes it (menuPressGuard.ts).
  useMenuPressGuard();
  const device = useDeviceChats();
  const closed = useRecentlyClosed();
  // Ages read the shared clock (clock.ts): every page shows the same age and changes it together.
  const clock = useMinuteClock();
  const at = now ?? clock;
  const cards = useMemo(
    () => recentChatCards(snapshot.sessions, at, t, device, sections.recent, sections.chats === "list"),
    [snapshot.sessions, at, t, device, sections.recent, sections.chats],
  );
  // With All chats on the page (the host answers `chats.page`) every chat is in that list, so
  // the cards keep only the chats that are running or need the user.
  const allChats = sections.allChats && !!props.loadChatsPage && !!props.onOpenChat;
  const activeCards = useMemo(() => cards.filter((card) => card.state !== "idle"), [cards]);
  // The stage layout's suggested actions start with the chats waiting on the user: one asking for
  // input, or one that hit an error or lost its agent.
  // Picked from every chat, not the trimmed recent cards (needsYouCards).
  const needsYou = useMemo(
    () => (stage ? needsYouCards(snapshot.sessions, at, t) : []),
    [stage, snapshot.sessions, at, t],
  );
  const openCard = (id: string) => {
    const key = cards.find((card) => card.sessionId === id)?.chatKey;
    if (key && props.onOpenChat) return props.onOpenChat(key);
    props.onOpenSession(id);
  };
  // A card's Open in Terminal, by its chat's key, as All chats opens one (only cards with a key offer it).
  const openCardInTerminal = (id: string) => {
    const key = cards.find((card) => card.sessionId === id)?.chatKey;
    if (key) props.onOpenChatInTerminal?.(key);
  };
  const list = useRef<HTMLDivElement>(null);
  // With no room under the box for every row, the rows go past the window's edge (cx-6k6cg); the
  // field keeps the keyboard and the list its highlight.
  const host = usePopupHost();
  const [shown, setShown] = useState<HTMLDivElement | null>(null);
  const attachList = useCallback(
    (node: HTMLDivElement | null) => {
      list.current = node;
      if (host) setShown(node);
    },
    [host],
  );
  // The suggestions' popover (Leo 2026-10-12) hangs under the composer box, on the popup layer:
  // it floats over every section, never covered and never moving the page.
  const [box, setBox] = useState<HTMLDivElement | null>(null);
  useEscapingPopup(host, shown, () => box, {
    // At the foot of the page the rows open over the composer.
    side: stage ? "top" : "bottom",
    align: "start",
    gap: UI_ANCHOR_GAP,
    kind: "list",
    shell: "parent",
    onDismiss: () => setDismissed(textRef.current),
  });
  const suggesting = rows.length > 0;
  useEffect(() => {
    if (!suggesting || !box) return;
    const document = box.ownerDocument;
    const press = (event: Event) => {
      const target = event.target as Element | null;
      if (target && (box.contains(target) || target.closest?.(".nt-popover"))) return;
      setDismissed(textRef.current);
    };
    document.addEventListener("pointerdown", press, true);
    document.addEventListener("mousedown", press, true);
    return () => {
      document.removeEventListener("pointerdown", press, true);
      document.removeEventListener("mousedown", press, true);
    };
  }, [suggesting, box]);
  // The box scrolls past its cap; the selected row stays in view. Only the box scrolls (not the
  // screen around it, as scrollIntoView would). A callback ref: it runs when a row becomes the
  // selected one.
  const keepInView = useCallback((row: HTMLElement | null) => {
    const box = list.current;
    if (!box || !row) return;
    const inner = box.getBoundingClientRect();
    const at = row.getBoundingClientRect();
    if (at.top < inner.top) box.scrollTop -= inner.top - at.top;
    else if (at.bottom > inner.bottom) box.scrollTop += at.bottom - inner.bottom;
  }, []);

  // The field is as tall as its draft, up to its cap (screen.css max-height), then it scrolls. It
  // fits again when the draft changes and when the pane's width changes (the lines rewrap). Its
  // scroll offset is kept, except that a caret at the draft's end (typing, a paste, dictation) is
  // scrolled into view: the engine revealed it before this fit changed the field's height.
  const fitField = useCallback(() => {
    const node = field.current;
    if (!node) return;
    const top = node.scrollTop;
    node.style.height = "0px";
    node.style.height = `${node.scrollHeight}px`;
    const typingAtEnd = node.ownerDocument.activeElement === node && node.selectionEnd === node.value.length;
    node.scrollTop = typingAtEnd ? node.scrollHeight : top;
  }, []);
  useLayoutEffect(fitField, [fitField, text, shell, template]);
  useLayoutEffect(() => {
    const caret = inlineCaret.current;
    if (caret === undefined) return;
    inlineCaret.current = undefined;
    field.current?.focus();
    field.current?.setSelectionRange(caret, caret);
  }, [text]);
  useEffect(() => {
    const node = field.current;
    const view = node?.ownerDocument.defaultView;
    if (!node || !view?.ResizeObserver) return undefined;
    let width = node.clientWidth;
    const observer = new view.ResizeObserver(() => {
      if (node.clientWidth === width) return;
      width = node.clientWidth;
      fitField();
    });
    observer.observe(node);
    // The web font can land after the first fit and rewrap the draft.
    void node.ownerDocument.fonts?.ready.then(fitField);
    return () => observer.disconnect();
  }, [fitField]);

  // The field takes the keyboard when the screen appears (in the commit, so an adopted spare's
  // field has focus before the next key) and on Cmd-L (FOCUS_LOCATION_EVENT); only then, so an
  // update or a click into the field never moves its caret or restarts its blink.
  useLayoutEffect(() => {
    const focus = () => {
      field.current?.focus();
      field.current?.select();
    };
    if (focusOnShow) focus();
    if (inputToken && inputReadyReported.current !== inputToken) {
      inputReadyReported.current = inputToken;
      onInputReady.current?.(inputToken);
    }
    const view = field.current?.ownerDocument.defaultView;
    view?.addEventListener(FOCUS_LOCATION_EVENT, focus);
    return () => view?.removeEventListener(FOCUS_LOCATION_EVENT, focus);
  }, [inputToken, focusOnShow]);

  const activate = (row: ScreenRow) => {
    switch (row.type) {
      case "search":
        return props.onSearch(row.text);
      case "open":
        return props.onOpen(row.url);
      case "history":
        return props.onOpen(row.url);
      case "tab":
        return props.onJump("tab", row.id);
      case "workspace":
        return props.onJump("workspace", row.id);
      case "ask":
        return askChat(row.harness, row.text, project, row.harness === harness ? chipModel : undefined);
      case "create":
        return row.kind === "chat" ? startChat() : create(row.kind);
    }
  };
  const edit = (next: string) => {
    touch();
    setTouched(true);
    const entry = composing.current || shell ? undefined : shellEntry(text, next, wholeSelection.current);
    wholeSelection.current = false;
    if (entry) {
      setShell(true);
      setText(entry.command);
      return;
    }
    setText(next);
    setSelected(undefined);
    setKeyboardPick(false);
  };
  const submit = () => {
    // Closed suggestions still answer Return: their top row ("reddit" opens reddit.com).
    const row = rows.length ? rows[current] : suggested[defaultSelection(suggested)];
    if (row) return activate(row);
    const prompt = text.trim();
    if (!prompt || isAddress(prompt, home)) return;
    // No agent to ask: the composer's chip says Add harness (ComposerPickers), so Return adds no note.
    if (!harness) return;
    askChat(harness, prompt, project, chipModel);
  };
  // One create per page: a double click, or a click while the terminal spawns, opens one tab.
  const created = useRef(false);
  const create = (kind: "terminal" | "browser") => {
    touch();
    if (created.current) return;
    created.current = true;
    props.onCreate?.(kind);
  };
  // New chat: Return's chat, with the prompt the field holds (an address or a shell command stays
  // behind: the chat starts empty).
  const startChat = () => {
    touch();
    if (!harness) return;
    if (created.current) return;
    created.current = true;
    const prompt = shell ? "" : text.trim();
    askChat(harness, prompt && !isAddress(prompt, home) ? prompt : "", project, chipModel);
  };
  const send = () => {
    touch();
    if (!shell) return submit();
    const command = text.trim();
    if (command) props.onShell(command);
  };
  const sendRef = useRef(send);
  sendRef.current = send;
  const editRef = useRef(edit);
  editRef.current = edit;
  const { dictationField } = props;
  useLayoutEffect(() => {
    if (!dictationField) return undefined;
    dictationField.current = {
      focus: () => field.current?.focus(),
      focused: () => document.activeElement === field.current,
      element: () => field.current,
      text: () => {
        const input = field.current;
        const value = input?.value ?? "";
        return {
          value,
          selectionStart: input?.selectionStart ?? value.length,
          selectionEnd: input?.selectionEnd ?? value.length,
        };
      },
      // Dictation splices its words in as typing would, committed at once: its next update reads
      // the field back, and auto-send sends what it holds.
      writeText: (value, selectionStart, selectionEnd) => {
        flushSync(() => editRef.current(value));
        field.current?.setSelectionRange(selectionStart, selectionEnd);
      },
      submit: () => sendRef.current(),
    };
    return () => {
      dictationField.current = null;
    };
  }, [dictationField]);
  // A key typed anywhere on the page goes into the field, the first key kept (Lawrence
  // 2026-10-09: "if i just start typing it needs to automatically start typing"). Another field
  // (a picker's search), a menu with its own keys, a chord and IME keep theirs.
  const typeAnywhere = useRef<(event: KeyboardEvent) => void>(() => undefined);
  typeAnywhere.current = (event) => {
    const input = field.current;
    if (!input || event.defaultPrevented || event.isComposing) return;
    if (event.metaKey || event.ctrlKey || event.altKey || event.key.length !== 1) return;
    const target = event.target as Element | null;
    const element = target && typeof target.closest === "function" ? target : undefined;
    if (target === input || (element && ownsKeys(element))) return;
    // Space on a focused button presses it.
    if (event.key === " " && element?.closest('button, a, summary, [role="button"]')) return;
    event.preventDefault();
    input.focus();
    // A location the page put in the field, still selected, is replaced as a typed key would.
    const whole = input.value !== "" && input.selectionStart === 0 && input.selectionEnd === input.value.length;
    wholeSelection.current = whole;
    edit(whole ? event.key : input.value + event.key);
  };
  const screen = useCallback((node: HTMLDivElement | null) => {
    const document = node?.ownerDocument;
    if (!document) return;
    const listener = (event: KeyboardEvent) => typeAnywhere.current(event);
    // ui-allow: the page's type-to-field rule needs every key that no control on the page takes.
    document.addEventListener("keydown", listener);
    return () => document.removeEventListener("keydown", listener);
  }, []);
  const focusFromRow = (event: React.MouseEvent<HTMLDivElement>) => {
    const input = field.current;
    if (!input || event.button !== 0 || event.target === input) return;
    // Keep the press from moving focus to the row; a field that had no focus gets the caret at
    // the end of its text, a focused one keeps its caret and selection.
    event.preventDefault();
    if (input.ownerDocument.activeElement === input) return;
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
  };
  const keyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    touch();
    if (composing.current || event.nativeEvent.isComposing) return;
    const input = event.currentTarget;
    if (shell) {
      if (event.key === "Enter") {
        event.preventDefault();
        const command = text.trim();
        if (command) props.onShell(command);
      } else if (event.key === "Escape" || (event.key === "Backspace" && input.selectionEnd === 0)) {
        // Leaves shell mode; what was typed stays in the field.
        event.preventDefault();
        setShell(false);
      }
      return;
    }
    wholeSelection.current =
      input.value !== "" && input.selectionStart === 0 && input.selectionEnd === input.value.length;
    const plain = !event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;
    const completion =
      plain && input.selectionStart === input.value.length && input.selectionEnd === input.value.length
        ? inlineCompletion(text, rows)
        : undefined;
    if ((event.key === "ArrowRight" || event.key === "End") && completion) {
      event.preventDefault();
      inlineCaret.current = completion.length;
      edit(completion);
      return;
    }
    if (event.key === "Tab" && plain && keyboardPick && current >= 0 && current < rows.length) {
      // Tab advances a highlight the keyboard already moved; Enter still performs the action.
      // Otherwise Tab is the browser's, so it moves focus on to Send.
      event.preventDefault();
      setSelected(stepSelection(current, 1, rows.length));
      return;
    }
    const step = listStep(event);
    if (step && rows.length) {
      event.preventDefault();
      setKeyboardPick(true);
      setSelected(stepSelection(current, step, rows.length));
    } else if (step && dismissed !== undefined && text) {
      // Down or Up on closed suggestions opens them again.
      event.preventDefault();
      setDismissed(undefined);
    } else if (event.key === "Enter" && event.shiftKey && !event.metaKey && !event.ctrlKey && !event.altKey) {
      // Shift-Return adds a line, as in the chat composer: the field keeps its own newline.
    } else if (event.key === "Enter") {
      event.preventDefault();
      submit();
    } else if (event.key === "Escape") {
      // The first Escape closes the suggestions, the next leaves the field; the text stays.
      event.preventDefault();
      if (rows.length) setDismissed(text);
      else input.blur();
    }
  };
  const pickProject = (cwd?: string) => {
    touch();
    setPicked(true);
    setNone(cwd === undefined);
    setProject(cwd);
    field.current?.focus();
    // The folder menu hands focus back to its button as it closes: the field takes it after that,
    // so Return sends instead of reopening the menu.
    requestAnimationFrame(() => field.current?.focus());
  };
  const localSessions = useMemo(
    () => snapshot.sessions.filter((session) => !session.peer && session.hostKind !== "cloud"),
    [snapshot.sessions],
  );
  const browseProject = props.onBrowseProject
    ? () => {
        void props.onBrowseProject?.().then((cwd) => {
          if (cwd) pickProject(cwd);
        });
      }
    : undefined;
  const Chips = props.chips;
  // Where the chat starts: the folder Enter asks in (askFolder), picked as in the agent composer's
  // location strip; never the home ~ the tab inherited (cx-7fje0). Over the box, or in the stage
  // layout the footer's first item, before the permission mode (Claude Code desktop's footer).
  const locationStrip = (
    <div className="nt-location" data-project-pending={projectPending || undefined} onPointerDownCapture={touch}>
      <ComposerContext
        summary={{
          ...chipSnapshot.summary,
          sessionId: chipSnapshot.summary?.sessionId ?? "",
          ...(askFolder ? { cwd: askFolder } : { cwd: undefined }),
        }}
        // A New Tab chat starts where the page runs (screenActions onAsk sends no peer): the
        // row lists only this machine's chats, so its Computer menu offers no other.
        sessions={localSessions}
        {...(props.machineName ? { localName: props.machineName } : {})}
        projectChoices={props.projects ?? []}
        onProject={(cwd) => pickProject(cwd)}
        onNoProject={() => pickProject(undefined)}
        noProject={none}
        {...(browseProject ? { onBrowseProject: browseProject } : {})}
      />
    </div>
  );
  // The page's lists: the widget view (Debug Settings), the open tabs to move here, Recently Closed
  // and the recent chats. In the stage layout they sit under the cards, over the composer.
  const lists = (
    <>
      {props.widgets && (
        <WidgetCards
          sessions={snapshot.sessions}
          projects={props.projects ?? []}
          {...(askFolder ? { folder: askFolder } : {})}
          {...(props.cwd ? { inherited: props.cwd } : {})}
          attention={!allChats}
          {...(props.machineName ? { machineName: props.machineName } : {})}
          onProject={pickProject}
          onOpen={openCard}
        />
      )}
      {props.openTabs && <OpenTabsList tabs={props.openTabs} onMoveHere={(id) => props.onJump("here", id)} />}
      {sections.closed && <ClosedList items={closed} onReopen={(id) => props.onJump("closed", id)} />}
      {sections.chats !== "none" && !allChats && (
        <ChatCards
          cards={cards}
          variant={sections.chats}
          onOpen={openCard}
          {...(props.onOpenChatInTerminal ? { onOpenInTerminal: openCardInTerminal } : {})}
          onShowAll={props.onShowAll}
        />
      )}
      {allChats && props.loadChatsPage && props.onOpenChat && (
        <AllChatsList
          load={props.loadChatsPage}
          onOpen={props.onOpenChat}
          active={activeCards.map((card) => ({
            id: card.sessionId,
            title: card.title,
            ...(card.harness ? { harness: card.harness } : {}),
            state: card.state,
            label:
              card.state === "failed"
                ? t("header.failed")
                : nt(`card.${card.state as "input" | "running" | "error" | "unread"}`),
          }))}
          onOpenActive={openCard}
          {...(props.onOpenChatInTerminal ? { onOpenInTerminal: props.onOpenChatInTerminal } : {})}
          {...(now !== undefined ? { now } : {})}
        />
      )}
    </>
  );
  // The folder Enter asks in (screenActions: the picked project, else the tab's), so a pick's
  // switch is the one Enter reuses.
  const chips = Chips && <Chips snapshot={chipSnapshot} {...(chatFolder ? { cwd: chatFolder } : {})} />;
  const composer = (
    <>
      {/* One card, the agent composer's (Composer.tsx; Leo 2026-10-13): the field on top, then the
          bar with the agent's model chip, the mic and Send. The location strip with the project the
          chat starts in heads it, as text over the card (ComposerContext, the composer's own; hq#1957
          composer location strip; newtab/screen.css); in the stage layout it is the bar's first item. */}
      <div className="nt-composer">
        {!stage && locationStrip}
        <div ref={setBox} className="nt-box">
          {/* A press anywhere on the field's row (its padding, the glyph) focuses the field, as a
            browser's address bar does; the text itself keeps its own press (caret, selection).
            Cursor rule (cx-d0d.80): the I-beam only over the text, the arrow elsewhere. */}
          {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- A pointer convenience only: the input inside is the control and takes the keyboard itself. */}
          <div className="nt-input" onMouseDown={focusFromRow}>
            {shell ? (
              <span className="nt-shell-glyph" aria-hidden="true">
                !
              </span>
            ) : (
              sections.prompt && (
                <span className="nt-prompt-glyph" aria-hidden="true">
                  &gt;
                </span>
              )
            )}
            {/* A textarea, not a one-line input (Austin: a typed draft was cut to its first line): a long
              draft wraps and the field grows with it up to its cap (screen.css), then scrolls. Return
              still sends; every line break is one the draft brought in (a paste). */}
            <textarea
              ref={field}
              className="nt-field"
              rows={1}
              data-focus-ring="none"
              aria-label={shell ? t("composer.shell") : nt("placeholder")}
              placeholder={shell ? t("composer.shellPlaceholder") : nt("placeholder")}
              value={text}
              aria-controls="nt-rows"
              aria-activedescendant={rows[current] ? `nt-row-${current}` : undefined}
              spellCheck={!shell}
              autoCapitalize="off"
              autoCorrect="off"
              onChange={(event) => edit(event.target.value)}
              onKeyDown={keyDown}
              onMouseDown={() => setDismissed(undefined)}
              onCompositionStart={() => {
                composing.current = true;
              }}
              onCompositionEnd={() => {
                composing.current = false;
              }}
            />
          </div>
          {/* The button row: a right-click here shows the mic hidden from its own (composerChrome.tsx);
            this page draws no context ring. */}
          <ChromeArea className="acpmux-chrome-area" items={[chrome.dictation]}>
            <div
              className="nt-pickers"
              data-footer-look={plainFooter && !stage ? "plain" : undefined}
              onPointerDownCapture={touch}
            >
              {/* In the stage layout the box holds only the field, the mic and Send; the chips are the
                quiet footer's under it (below). */}
              {!stage && chips}
              <span className="acpmux-composer-actions">
                {props.accessory}
                {/* Send: a click does what Return does (a prompt, a row, or a shell command). */}
                <button
                  type="button"
                  className={text.trim() ? "acpmux-send acpmux-send-ready nt-send" : "acpmux-send nt-send"}
                  aria-label={t("composer.send")}
                  title={t("composer.sendTooltip")}
                  disabled={!text.trim()}
                  onClick={send}
                >
                  <ArrowUpIcon />
                </button>
              </span>
            </div>
          </ChromeArea>
        </div>
        {stage && (
          // Claude Code desktop's footer, under the box (Leo 2026-10-19; the composer's split): the
          // folder and the permission mode on the left, the model and effort on the right, as text.
          <div className="nt-footer" data-footer-look={plainFooter ? "plain" : undefined} onPointerDownCapture={touch}>
            {locationStrip}
            {chips}
          </div>
        )}
      </div>
    </>
  );
  return (
    <div
      ref={screen}
      className="nt-screen"
      data-shell={shell || undefined}
      data-template={template}
      data-all-chats={allChats || undefined}
      data-layout={stage ? "stage" : undefined}
    >
      {stage ? (
        <>
          {/* Claude Code desktop's new-session screen (Leo 2026-10-19): the free space over the
              composer holds, centered, the environment card and the suggested actions card, then the
              recent chats; it scrolls on its own, so nothing in it ever moves the composer. */}
          <div className="nt-stage">
            <div className="nt-stage-cards">
              <EnvironmentCard
                projects={props.projects ?? []}
                {...(envFolder ? { current: envFolder } : {})}
                noProject={none}
                {...(props.machineName ? { machineName: props.machineName } : {})}
                onPick={(cwd) => pickProject(cwd)}
                onNoProject={() => pickProject(undefined)}
                {...(browseProject ? { onBrowse: browseProject } : {})}
              />
              <SuggestionsCard
                attention={needsYou}
                onOpen={openCard}
                {...(props.onCreate ? { onCreate: create } : {})}
                onChat={startChat}
              />
            </div>
            {!allChats && <NowPlayingPlayer {...(props.onNowPlaying ? { onCommand: props.onNowPlaying } : {})} />}
            {lists}
          </div>
          {composer}
          {props.notice}
        </>
      ) : (
        <>
          {composer}
          {props.notice}
          {/* The create actions (cx-ag5.7, dogfood call K2): a blank terminal in the tab's folder, a
              browser tab on the new tab page, or this page as an empty chat with the agent Return asks.
              Not beside All chats: that list takes the room under the field (new-tab-scroll). */}
          {!allChats && (
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            <div className="nt-create ui-ghost-row" role="group" aria-label={nt("create.label")}>
              {props.onCreate && (
                <>
                  <button
                    type="button"
                    className="nt-tool ui-ghost"
                    data-create="terminal"
                    onClick={() => create("terminal")}
                  >
                    <span className="nt-tool-icon ui-ghost-icon" aria-hidden="true">
                      <Icon name="terminal" size={14} />
                    </span>
                    <span>{nt("create.terminal")}</span>
                  </button>
                  <button
                    type="button"
                    className="nt-tool ui-ghost"
                    data-create="browser"
                    onClick={() => create("browser")}
                  >
                    <span className="nt-tool-icon ui-ghost-icon" aria-hidden="true">
                      <Icon name="browser" size={14} />
                    </span>
                    <span>{nt("create.browser")}</span>
                  </button>
                </>
              )}
              <button type="button" className="nt-tool ui-ghost" data-create="chat" onClick={startChat}>
                <span className="nt-tool-icon ui-ghost-icon" aria-hidden="true">
                  <Icon name="agent.chat" size={14} />
                </span>
                <span>{nt("create.chat")}</span>
              </button>
            </div>
          )}
          {!allChats && <NowPlayingPlayer {...(props.onNowPlaying ? { onCommand: props.onNowPlaying } : {})} />}
          {lists}
        </>
      )}
      {rows.length > 0 && box && (
        <Popover
          open
          // The rows follow the field (Escape there and a press outside close them): the popover
          // never closes itself.
          onOpenChange={() => undefined}
          anchor={box}
          side={stage ? "top" : "bottom"}
          label={nt("suggestions")}
          className="nt-popover"
          initialFocus={false}
          finalFocus={false}
        >
          {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
          <div ref={attachList} className="nt-rows" id="nt-rows" role="listbox" aria-label={nt("suggestions")}>
            {rows.map((row, index) => (
              <div
                key={rowKey(row)}
                id={`nt-row-${index}`}
                ref={index === current ? keepInView : undefined}
                // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                role="option"
                tabIndex={-1}
                aria-selected={index === current}
                data-type={row.type}
                className={index === current ? "nt-row is-selected" : "nt-row"}
                onMouseMove={() => {
                  if (index === current) return;
                  setKeyboardPick(false);
                  setSelected(index);
                }}
                onMouseDown={(event) => {
                  event.preventDefault();
                  activate(row);
                }}
              >
                {rowFavicon(row) ? (
                  <img className="nt-row-glyph nt-row-favicon" src={rowFavicon(row)} alt="" draggable={false} />
                ) : (
                  <RowGlyph kind={rowGlyph(row)} />
                )}
                <span className="nt-row-title">{rowTitle(nt, row)}</span>{" "}
                {rowDetail(row) && <span className="nt-row-detail">{rowDetail(row)}</span>}
                <span className="nt-row-action" data-popup-skip>
                  {rowAction(t, nt, row)}
                  {index === current && <kbd>↵</kbd>}
                </span>
              </div>
            ))}
          </div>
        </Popover>
      )}
    </div>
  );
}

/// Down or Ctrl-N is 1, Up or Ctrl-P is -1 (R85: the native list.next keys, here for a field
/// that is not a list until rows show); anything else undefined. A modified arrow (Shift, Cmd,
/// Option) moves or extends the caret, as in a browser's address bar (cx-ag5.8).
function listStep(event: React.KeyboardEvent): 1 | -1 | undefined {
  const plain = !event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;
  if (event.key === "ArrowDown") return plain ? 1 : undefined;
  if (event.key === "ArrowUp") return plain ? -1 : undefined;
  if (!event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return undefined;
  if (event.key === "n") return 1;
  if (event.key === "p") return -1;
  return undefined;
}

/// A control that takes typed keys itself: a text field, or a menu or list with type-ahead.
function ownsKeys(element: Element): boolean {
  if ((element as HTMLElement).isContentEditable || element.closest("input, textarea, select")) return true;
  return element.closest('[role="menu"], [role="listbox"], [role="dialog"], [role="combobox"]') !== null;
}

function rowKey(row: ScreenRow): string {
  switch (row.type) {
    case "tab":
      return `tab:${row.id}`;
    case "history":
      return `history:${row.url}`;
    case "open":
      return `open:${row.url}`;
    case "workspace":
      return `workspace:${row.id}`;
    case "create":
      return `create:${row.kind}`;
    default:
      return row.type;
  }
}

/// A create row draws its button's icon; the others their type's.
function rowGlyph(row: ScreenRow) {
  if (row.type !== "create") return row.type;
  return row.kind === "chat" ? "agent" : row.kind;
}

/// A tab's or visited page's favicon (cx-d0d.8): it takes the glyph's place when the host sent one.
function rowFavicon(row: ScreenRow): string | undefined {
  return row.type === "tab" || row.type === "history" ? row.icon : undefined;
}

function rowTitle(nt: NewTabTranslate, row: ScreenRow): string {
  switch (row.type) {
    case "search":
      return nt("row.searchFor", { text: row.text });
    case "ask":
      return nt("row.ask", { agent: row.agent });
    case "open":
      return row.text;
    case "history":
      return row.title ?? canonicalAddress(row.url);
    case "tab":
    case "workspace":
      return row.title;
    case "create":
      return nt(`create.${row.kind}`);
  }
}

function rowDetail(row: ScreenRow): string | undefined {
  switch (row.type) {
    case "open":
      return row.url === row.text ? undefined : row.url;
    case "history":
      return row.title ? shortHost(row.url) : undefined;
    case "tab":
    case "workspace":
      return row.detail;
    case "ask":
      return row.model;
    default:
      return undefined;
  }
}

function rowAction(t: Translate, nt: NewTabTranslate, row: ScreenRow): string {
  switch (row.type) {
    case "search":
    case "open":
      return t("newTabPage.row.open");
    case "ask":
      return t("composer.send");
    case "workspace":
      return nt("row.workspace");
    case "tab":
      return t("newTabPage.row.tab");
    case "history":
      return t("newTabPage.row.history");
    case "create":
      return t("newTabPage.row.open");
  }
}
