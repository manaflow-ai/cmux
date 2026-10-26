import { useWebSwapHold } from "../../../pages/shared/useWebSwapHold";
import { WEB_SWAP_KEPT_TEXT } from "../../../pages/shared/webSwap";
import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import type { ConnectKind } from "../environments";
import type { DictationField } from "../dictation";
import { FOCUS_LOCATION_EVENT, type NewTabHost } from "../NewTabPage";
import type { AcpmuxSnapshot } from "../model";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../omnibar";
import { ComposerContext } from "../ComposerContext";
import { OnNewTab } from "../newTabComposer";
import type { Project } from "../ProjectChooser";
import { firstProject, isAgentHome, mostRecentProject, projectLabel } from "../sessionList";
import { WorktreeFailure } from "../startFolder";
import type { SavedEnvironment, SavedEnvironmentHost } from "../environments";
import { SavedEnvironmentPanel } from "../SavedEnvironmentPanel";
import { useSavedEnvironments } from "./savedEnvironments";
import type { ComposerAttachment, DroppedKind, LinkItem } from "../attachments";
import type { UploadResult } from "../cloudUploads";
import {
  AttachmentStrip,
  backspacedAttachment,
  useAttachmentIntake,
  useSendWhenAttached,
} from "../composer/attachmentIntake";
import { reordered } from "../composer/stripReorder";
import { DropOverlay } from "../composer/DropOverlay";
import { AllChatsList, type LoadChatsPage } from "./AllChatsList";
import { ChatCards } from "./ChatCards";
import { ClosedList } from "./ClosedList";
import { OpenTabsList } from "./OpenTabsList";
import { type NowPlayingCommand, NowPlayingPlayer } from "./NowPlayingPlayer";
import { ArrowUpIcon, PaperclipIcon, Picker, PlusIcon } from "../ComposerPickers";
import { newTabStart, useNewTabChipModel } from "./chipDefaults";
import { useLastPick } from "../lastPick";
import { useDeviceChats } from "./deviceChats";
import { useRecentlyClosed } from "./recentlyClosed";
import { initialRecentProject } from "./recentProject";
import { rememberedStartedProject } from "./startedProject";
import {
  canonicalAddress,
  defaultSelection,
  isAddress,
  pairingLinkRefused,
  inlineCompletion,
  needsYouCards,
  recentChatCards,
  screenRows,
  inStrip,
  shellEntry,
  shortHost,
  stepSelection,
  type CreateKind,
  type ScreenRow,
} from "./screenModel";
import { RowGlyph } from "./RowGlyph";
import { WidgetCards } from "./WidgetCards";
import { NewTabHeadline } from "./NewTabHeadline";
import {
  shownMovable,
  shownPageWidgets,
  type MovableWidget,
  type PageWidget,
  type PageWidgets,
  type WidgetEdit,
} from "./pageWidgets";
import { useWidgetEditing, WidgetEditBar, WidgetFrame } from "./WidgetEditing";
import { useNoEntryMotion } from "./noEntryMotion";
import { ContextMenu } from "../../../ui/ContextMenu";
import { AmbientWidgets } from "./AmbientWidgets";
import type { NewTabWeather } from "./ambient";
import { EnvironmentCard, SuggestionsCard } from "./StageCards";
import { Icon } from "../icons/Icon";
import { type NewTabTranslate, useNt } from "./strings";
import { screenSections, type ScreenTemplate } from "./templates";
import { type Translate, useT } from "../i18n";
import { ChromeArea } from "../../../ui/HideableChrome";
import { Popover } from "../../../ui/Popover";
import { PromptFocus } from "../promptFocus";
import { useEscapingPopup } from "../../../ui/popupHost";
import { usePopupHost } from "../../../ui/UiProvider";
import { UI_ANCHOR_GAP } from "../../../ui/anchor";
import { useComposerChrome } from "../composerChrome";
import { useComposerSettings } from "../composerSettings";
import { useComposerLook } from "../composerLook";
import { ComposerFoot } from "../ComposerFoot";
import { useRowFit } from "../composerRowFit";
import { useMenuPressGuard } from "../menuPressGuard";
import { useMinuteClock } from "../clock";
import { usePasteAnywhere } from "../composer/pasteAnywhere";
import { SlashMenu } from "../SlashMenu";
import { applyCommand, matchCommands, slashQuery, type SlashCommand } from "../slashCommands";
import { useHarnessesListed } from "../catalog";
import { NewTabExtras } from "./NewTabExtras";
import type { SuggestionOrder } from "./suggestionOrder";

/// What the screen asks the host to do. A prompt stays in the page (the tab becomes the chat).
export type NewTabScreenActions = {
  /// Enter on a prompt: a chat with `harness` in `cwd` (the project picked on the page).
  /// `model`: the one the chip names, so the chat starts on what the page showed.
  /// `noProject`: Do not work in a project was picked, so the chat starts in no project.
  /// `attachments`: what was pasted or dropped on the page (composer/attachmentIntake.tsx), sent
  /// with the chat's first prompt.
  /// `saved`: a saved environment picked the place. `cwd` is its folder, used even when it is the
  /// tab's own; with `peer` (an SSH environment's machine) a folder there.
  onAsk(
    harness: string,
    text: string,
    cwd?: string,
    model?: string,
    noProject?: boolean,
    attachments?: ComposerAttachment[],
    saved?: { peer?: string },
  ): void;
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
  onViewChat?(key: string): void;
  /// One page of All chats from the host (`chats.page`); without it the page shows no All chats list.
  loadChatsPage?: LoadChatsPage;
  onShowAll(): void;
  onInputReady?(token: string): void;
  /// The first user input reached the page (the host recycles only an untouched page, R81).
  onTouched?(): void;
  /// The machine the page runs on and its chat starts on (the host's name for it), for the
  /// location row's computer.
  machineName?: string;
  /// Preview features on: the location row's computer is the environment picker (ComposerContext).
  environments?: boolean;
  /// The environment picker's New environment: the host's SSH and cmux Cloud connect flows.
  onConnect?(kind: ConnectKind): void;
  /// With `environments`, New Worktree beside the folder: the host makes a worktree of `cwd` and
  /// this resolves to the folder the chat starts in (startFolder.tsx newWorktree); rejects with the
  /// host's reason.
  onNewWorktree?(cwd: string): Promise<string | undefined>;
  /// With `environments`, the host's saved environments (`environment.list/save/remove`): the
  /// environment picker lists them and Create environment makes one.
  savedEnvironments?: SavedEnvironmentHost;
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
  /// folder never becomes the start project. Absent or empty (not loaded yet), every local chat
  /// folder counts; `null` (the host answered with no project), none does.
  knownProjects?: readonly string[] | null;
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
  /// The app's copy of the project of the chat the person last picked and started
  /// (newtab/startedProject.ts; this run's own copy wins): where a tab with no folder of its own
  /// starts, before the newest chat's folder (which agents move).
  startedProject?: string;
  /// The projects the picker offers (App's newTabProjects).
  projects?: Project[];
  /// The host's folder panel; resolves with the folder picked, if any.
  onBrowseProject?(): Promise<string | undefined>;
  chips?: NewTabChips;
  /// Lazily load the chosen harness's actual commands in a deferred chat.
  onCommands?(harness: string, cwd?: string): void;
  /// false: the field does not take the keyboard when the screen appears (Cmd-L gave it to the
  /// omnibar); Cmd-L on the page still focuses it when the page shows no omnibar.
  focusField?: boolean;
  /// Which screen template draws the page (newtab/templates.ts); "default" when unset.
  template?: ScreenTemplate;
  /// The widget view (Debug Settings `newTab.widgets`): the Projects and Needs you cards.
  widgets?: boolean;
  /// The page's widgets (`tabs.newTabWidgets.*`, pageWidgets.ts): on Minimal, without them the page
  /// is the composer alone. Unset shows the template's own (shownPageWidgets).
  pageWidgets?: PageWidgets;
  /// true: `tabs.newTabWidgets.greeting` is set to false (not the default): with the headline off,
  /// Minimal keeps no room for it, so the composer sits where it sat with the greeting off.
  headlineOff?: boolean;
  /// How the rows under the field rank (screenModel.ts SuggestionOrder); unset is the default.
  suggestionOrder?: SuggestionOrder;
  /// false: Show All Chats on New Tab is off (`sidebar.showChats`): the recent chats show where
  /// the template would list All chats.
  allChats?: boolean;
  /// Minimal's edit mode saved an edit (WidgetEditing.tsx); unset, the page has no edit mode.
  onEditWidgets?(edit: WidgetEdit): void;
  /// The weather widget's last reading (the handshake's `weather`, ambient.ts); drawn while the
  /// `weather` widget is on.
  weather?: NewTabWeather;
  /// Buttons before Send, such as the dictation mic (DictationMic).
  accessory?: React.ReactNode;
  /// Why dictation did not run (DictationNotice), under the field.
  notice?: React.ReactNode;
  /// Where the page's dictation writes: the field, while the screen shows.
  dictationField?: React.MutableRefObject<DictationField | null>;
  /// A dictation session is waiting for words: the empty field reads "Listening…" in italic.
  dictating?: boolean;
  /// On this Mac: where the files of the person's drop or paste are, so a folder or a file no prompt
  /// block takes goes with the first prompt as a link to it (the page has no upload to save one).
  localPaths?(kind: DroppedKind, files: File[]): Promise<LinkItem[] | undefined>;
  /// Saves files chosen from the New Tab plus menu when the session has no chat upload yet.
  upload?(files: File[]): Promise<UploadResult>;
};

/// `/`, `/Users`, a home folder: never a chat's start folder (AgentPaneStartFolders drops them).
function homeOrAbove(cwd: string | undefined): boolean {
  return !cwd || /^\/(?:(?:Users|home)(?:\/[^/]+)?)?\/?$/.test(cwd);
}

/// Whether the engine sizes `field` to its draft itself (screen.css `field-sizing: content`).
function sizesItself(field: HTMLTextAreaElement): boolean {
  return field.ownerDocument.defaultView?.CSS?.supports?.("field-sizing", "content") ?? false;
}

/// How long the folder chip holds its place for a daemon that has not listed the chats yet.
const RESERVE_MS = 2_000;
const NO_DEVICE_CHATS: ReturnType<typeof useDeviceChats> = [];

/// The new tab screen, variant B (plans/cmux-next/new-tab.md): the project and model pickers on
/// top, then one field that reads what is typed (`!` a shell command, an address, or a prompt for
/// the picked agent, R86), the rows for addresses and open tabs only when they make sense
/// (cx-e2aa), and the recent chats as cards. A key typed anywhere on the page goes to the field.
export function NewTabScreen(props: Props) {
  const nt = useNt();
  // What the page shows or opens appears at once; exits keep their fades (noEntryMotion.ts).
  useNoEntryMotion();
  const { snapshot, omnibar = EMPTY_OMNIBAR, location, lastAgent, home, now, inputToken } = props;
  const template = props.template ?? "default";
  const sections = screenSections(template);
  const widgets = props.pageWidgets ?? shownPageWidgets(template);
  // Claude Code desktop's new-session page (templates.ts stage, the Default template): the composer
  // at the foot, the environment and suggestions cards over it. On Minimal with neither the project
  // card nor the chats on, the page is the plain one: the composer (and the headline, if it is on),
  // and with the quick actions on (the second dot, PageDots.tsx) New terminal, New browser tab and New
  // chat as pills under it (Lucas 2026-10-22: "add the pills for "New terminal", "New browser", "New
  // chat" back"), never the stage's card. Default, which always shows its cards, keeps its stage.
  const stage =
    sections.stage &&
    (widgets.has("projects") || widgets.has("chats") || (template !== "minimal" && widgets.has("actions")));
  // The composer, at most the headline over it and the pills when on (Minimal, Leo 2026-10-20): the
  // composer sits about the window's middle.
  const minimal = !stage && !widgets.has("chats");
  // Minimal's edit mode (right-click > Edit New Tab): its widgets wiggle, move and close.
  const onEditWidgets = template === "minimal" ? props.onEditWidgets : undefined;
  const editing = useWidgetEditing(onEditWidgets);
  const order = shownMovable(widgets);
  const [text, setText] = useState(location ?? "");
  const [commandActive, setCommandActive] = useState(0);
  const [commandDismissed, setCommandDismissed] = useState<string>();
  const requestedCommands = useRef<string | undefined>(undefined);
  // The location stays a suggestion until edited: no rows for it.
  const [touched, setTouched] = useState(false);
  // The highlighted row, by its rowKey (NO_ROW: none, so Enter is the prompt's). A key, not an
  // index: new tabs or pages from the host can reorder the rows under a highlight.
  const [selected, setSelected] = useState<string | undefined>(undefined);
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
  if (
    latched !== undefined &&
    (props.knownProjects === null || (known && !known.some((path) => path.replace(/(.)\/+$/, "$1") === latched)))
  )
    setLatched(undefined);
  else if (latched === undefined && candidate !== undefined && (props.knownProjects === undefined || known))
    setLatched(candidate);
  // The project of the chat the person last picked and started wins over the newest chat's folder
  // (Leo 2026-10-21): chats agents start move that one. Not on another machine's page (no `home`),
  // and only a folder the host's project list still has. Read once, as the page mounts.
  const [startedProject] = useState(() => rememberedStartedProject() ?? props.startedProject);
  const started =
    startsRecent && home && startedProject
      ? firstProject([startedProject.replace(/(.)\/+$/, "$1")], home, props.knownProjects)
      : undefined;
  const recent = startsRecent ? (started ?? latched ?? candidate) : undefined;
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
  // Cmd-V anywhere on the page outside a text field (a row, a card, the empty page) goes into the
  // field, caret at the end, as in a chat (composer/pasteAnywhere.ts; Leo 2026-10-22: "cmd v anywhere
  // in chat should put it in chat").
  usePasteAnywhere(() => {
    const input = field.current;
    if (!input) return false;
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
    return true;
  });
  // A paste on the field (an image, a copied file, a screenshot) and a file drop anywhere on the
  // page stage attachments, as a chat's composer does (composer/attachmentIntake.tsx).
  const {
    attachments,
    setAttachments,
    pending: reading,
    unsettled,
    videoReading,
    cancel,
    retry,
    attachError,
    drop,
    dropLanded,
    attach,
  } = useAttachmentIntake({
    allowImages: snapshot.summary?.promptCapabilities?.image !== false,
    dropZone: () => field.current?.closest(".acpmux-main") ?? null,
    // Shell mode turns the page into a terminal, which takes no attachment: the paste stays text.
    pasteTarget: (target) => (!shell && field.current?.contains(target) ? { uploads: false } : undefined),
    ...(props.upload ? { upload: props.upload } : {}),
    ...(props.localPaths ? { localPaths: props.localPaths } : {}),
  });
  // Unlike a chat's composer, the new tab waits for uploads too (#25191): the page goes when the
  // chat starts, so a file still streaming has no next prompt to go with. A video's read is waited
  // for a few seconds at most (composer/videoAttachments.ts).
  const holdForAttachments = useSendWhenAttached(unsettled + videoReading);
  // WEB-SWAP: a web update's reload would lose what this page holds only in its state: a typed
  // query (the location comes back with the page) and staged attachments (pages/shared/webSwap.ts).
  useWebSwapHold(
    text !== (location ?? "") ? "newtab.draft" : attachments.length || reading.length ? "newtab.attachments" : null,
  );
  // The page a file drag covers with the drop overlay (composer/DropOverlay.tsx); a drop lands in the field.
  const [dropHost, setDropHost] = useState<Element | null>(null);
  useLayoutEffect(() => {
    const element = field.current;
    setDropHost(element ? (element.closest(".acpmux-main") ?? element.ownerDocument.body) : null);
  }, []);
  const dropLandingTarget = useCallback(() => field.current?.parentElement ?? null, []);
  const submitNow = useRef(() => {});
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
  // A saved environment the picker picked names where the chat starts (askInEnvironment).
  const saved = useSavedEnvironments(props.environments ? props.savedEnvironments : undefined);
  const environment = saved.picked;
  // WEB-SWAP: a reload also loses a pick the page keeps only in its state: shell mode, a folder or
  // no folder, a saved environment, one being edited (pages/shared/webSwap.ts).
  const editingEnvironment = saved.on && saved.editing !== undefined;
  useWebSwapHold(shell || picked || none || environment || editingEnvironment ? "newtab.choice" : null);
  // A real pick names its folder; else the folder the chat really starts in (screenActions onAsk).
  const chatFolder = environment
    ? environment.kind === "local"
      ? environment.folder
      : undefined
    : none
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
  const envFolder = none
    ? undefined
    : (askFolder ?? (props.cwd && !folderless && !homeOrAbove(props.cwd) ? props.cwd : undefined));
  // A prompt's chat, in no project when that was the pick.
  // The images and files pasted or dropped on the page go with the first prompt.
  const askChat = (agent: string, prompt: string, cwd?: string, model?: string) => {
    if (environment) return askInEnvironment(environment, agent, prompt, model);
    if (attachments.length > 0) return props.onAsk(agent, prompt, cwd, model, none || undefined, attachments);
    return none ? props.onAsk(agent, prompt, cwd, model, true) : props.onAsk(agent, prompt, cwd, model);
  };
  // The agent Enter asks and the chip's model (newTabStart): the chip's pick, else the last pick.
  const remembered = useLastPick(chatFolder);
  const harnessesListed = useHarnessesListed();
  const { harness, snapshot: chipSnapshot } = useMemo(
    () => newTabStart(snapshot, agents, lastAgent, chatFolder, remembered, harnessesListed),
    [snapshot, agents, lastAgent, chatFolder, remembered, harnessesListed],
  );
  const chipModel = useNewTabChipModel(chipSnapshot);
  // The Ask row names the agent Return asks and the model on its chip.
  const ask = useMemo(() => {
    const entry = snapshot.catalog.find((agent) => agent.id === harness);
    if (!harness || !entry) return undefined;
    const model = entry.models.find((option) => option.id === chipSnapshot.summary?.model)?.name;
    return { harness, agent: entry.name, ...(model ? { model } : {}) };
  }, [snapshot.catalog, harness, chipSnapshot.summary?.model]);
  const commandQuery = slashQuery(text, text.length);
  const commandMatches = commandQuery === undefined ? [] : matchCommands(snapshot.commands ?? [], commandQuery);
  const commandsOpen = commandQuery !== undefined && commandDismissed !== text && commandMatches.length > 0;
  const commandIndex = Math.min(commandActive, Math.max(0, commandMatches.length - 1));
  const onCommands = props.onCommands;
  const pickCommand = (command: SlashCommand) => {
    setText(applyCommand(text, text.length, command).text);
    setCommandActive(0);
    requestAnimationFrame(() => field.current?.focus());
  };
  useEffect(() => {
    if (commandQuery === undefined) {
      requestedCommands.current = undefined;
      return;
    }
    const key = `${harness}\u0000${chatFolder}`;
    if (harness && !snapshot.summary?.sessionId && requestedCommands.current !== key) {
      requestedCommands.current = key;
      onCommands?.(harness, chatFolder);
    }
  }, [commandQuery, harness, chatFolder, snapshot.summary?.sessionId, onCommands]);
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
    () =>
      touched && !shell && commandQuery === undefined
        ? screenRows(text, {
            omnibar,
            home,
            create: creates,
            ...(ask ? { ask } : {}),
            createNames: { terminal: nt("create.terminal"), browser: nt("create.browser"), chat: nt("create.chat") },
            ...(props.suggestionOrder ? { order: props.suggestionOrder } : {}),
          })
        : [],
    [touched, shell, text, omnibar, home, ask, creates, commandQuery, props.suggestionOrder, nt],
  );
  const rows = text !== dismissed ? suggested : [];
  // New tabs or pages from the host can shorten the rows under a highlight.
  // A highlighted row that went away (its tab closed) hands Return back to the top row.
  const kept = selected === undefined ? -1 : rows.findIndex((row) => rowKey(row) === selected);
  const current = selected === undefined || (kept < 0 && selected !== NO_ROW) ? defaultSelection(rows) : kept;
  const pick = (index: number) => {
    const row = rows[index];
    setSelected(row ? rowKey(row) : NO_ROW);
  };
  const t = useT();
  const chrome = useComposerChrome();
  // The chat composer's footer look (composerSettings.ts plainFooter): the New Tab row draws the
  // same plain chips, so the two composers never disagree (composerLocation.css).
  const { plainFooter, spellChecking } = useComposerSettings();
  // The quiet row's labels step down with the composer's width, as the chat's (composerRowFit.ts).
  const foot = useRef<HTMLDivElement>(null);
  // Claude Code's split (Leo 2026-10-19, "the claude code style composer on the first dot ... the
  // existing composer on the second one"): with the plain footer on, every template but Default
  // (the page's second dot) draws the chat composer's split, the mode, model and effort in a quiet
  // row under the box. Default keeps the chips in the box, as before the split.
  // Codex's look (the page's second dot, composerLook.ts) keeps them in the box's row too.
  const look = useComposerLook();
  // Either look draws the chat composer's box (Cards too, its strip Codex's tray); only the plain
  // footer off keeps Cards' pill.
  const chatBox = plainFooter && props.chips !== undefined && template !== "default";
  const split = chatBox && look === "claude";
  useRowFit(foot, split);
  // A press outside an open chip menu only closes it (menuPressGuard.ts).
  useMenuPressGuard();
  const pushed = useDeviceChats();
  // Before the daemon lists the chats, the device chats wait with them (at most RESERVE_MS): a cold
  // page fills its list once, not the device chats first and the chats above them after.
  const [chatsReserveOver, setChatsReserveOver] = useState(false);
  const holdChats = props.chatsPending === true && !chatsReserveOver;
  useEffect(() => {
    if (!holdChats) return;
    const timer = setTimeout(() => setChatsReserveOver(true), RESERVE_MS);
    return () => clearTimeout(timer);
  }, [holdChats]);
  const device = holdChats ? NO_DEVICE_CHATS : pushed;
  const closed = useRecentlyClosed();
  // Ages read the shared clock (clock.ts): every page shows the same age and changes it together.
  const clock = useMinuteClock();
  const at = now ?? clock;
  const cards = useMemo(
    () => recentChatCards(snapshot.sessions, at, t, device, sections.recent, sections.chats === "list"),
    [snapshot.sessions, at, t, device, sections.recent, sections.chats],
  );
  // With All chats on the page (the host answers `chats.page`) every chat is in that list, so
  // the cards keep only the chats that are running or need the user. Show All Chats off
  // (`sidebar.showChats`) keeps the recent chats in its place.
  const allChats =
    widgets.has("chats") &&
    sections.allChats &&
    props.allChats !== false &&
    !!props.loadChatsPage &&
    !!props.onOpenChat;
  const activeCards = useMemo(() => cards.filter((card) => card.state !== "idle"), [cards]);
  // The stage layout's suggested actions start with the chats waiting on the user: one asking for
  // input, or one that hit an error or lost its agent. Picked from every chat, not the trimmed
  // recent cards (needsYouCards).
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
  // With the split, the mode, model and effort sit in the quiet row under the box: the rows hang
  // under the whole composer instead, so they never cover those controls (a press there would pick
  // a row).
  const [composer, setComposer] = useState<HTMLDivElement | null>(null);
  const anchor = split ? (composer ?? box) : box;
  useEscapingPopup(host, shown, () => anchor, {
    // At the foot of the page (the stage layout) the rows open over the composer.
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
    // A press in the box, or with the split in the quiet row under it, keeps the rows.
    const press = (event: Event) => {
      const target = event.target as Element | null;
      if (target && (box.contains(target) || target.closest?.(".nt-popover, .nt-foot"))) return;
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

  // The field is as tall as its draft, up to its cap (screen.css max-height), then it scrolls. The
  // CSS sizes it (`field-sizing: content`), in the same layout as the pane's: a resize rewraps and
  // refits it with no script, no forced layout and no frame late (Leo 2026-10-20, "the new tab area
  // resizing calculation is slow and wack"; new-tab-live-resize). Only an engine without
  // field-sizing fits it here, when the draft changes and when the pane's width changes. Its scroll
  // offset is kept, except that a caret at the draft's end (typing, a paste, dictation) is scrolled
  // into view: the engine revealed it before this fit changed the field's height. WebKit sizes the
  // field itself but leaves a draft past the cap scrolled where it was, so a draft that changes with
  // the caret at its end scrolls to it there too (on the draft only, never on a resize).
  const fitField = useCallback(() => {
    const node = field.current;
    if (!node) return;
    const typingAtEnd = node.ownerDocument.activeElement === node && node.selectionEnd === node.value.length;
    if (sizesItself(node)) {
      if (typingAtEnd && node.scrollHeight > node.clientHeight) node.scrollTop = node.scrollHeight;
      return;
    }
    const top = node.scrollTop;
    node.style.height = "0px";
    node.style.height = `${node.scrollHeight}px`;
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
    if (!node || !view?.ResizeObserver || sizesItself(node)) return undefined;
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
    // The page got the keyboard back (a tab or pane switch back: WebKit focuses the window as its
    // web view becomes first responder) with nothing in it focused, as after a press on the page's
    // background: the field takes it, as the chat composer does (composerFocus.ts), keeping its
    // caret and the page's scroll. A field, menu or button that has focus keeps it.
    const reclaim = () => {
      const active = field.current?.ownerDocument.activeElement;
      if (!active || active === field.current?.ownerDocument.body) field.current?.focus({ preventScroll: true });
    };
    if (focusOnShow) view?.addEventListener("focus", reclaim);
    return () => {
      view?.removeEventListener(FOCUS_LOCATION_EVENT, focus);
      view?.removeEventListener("focus", reclaim);
    };
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
  };
  const submit = () => {
    // A pairing link (its room secret) is never searched, asked or opened: the host refuses it
    // with the address bar's word, and the page keeps the text.
    if (!shell && pairingLinkRefused(text)) return props.onOpen(text.trim());
    // A screenshot pasted a moment ago is still being read: Return goes once its chip is ready.
    if (holdForAttachments(() => submitNow.current())) return;
    // Closed suggestions still answer Return: their top row ("reddit" opens reddit.com).
    const row = rows.length ? rows[current] : suggested[defaultSelection(suggested)];
    // Staged attachments go with a chat: a row that opens a page or a tab would drop them.
    const keeps =
      !row || attachments.length === 0 || row.type === "ask" || (row.type === "create" && row.kind === "chat");
    if (row && keeps) return activate(row);
    const prompt = text.trim();
    // Pasted or dropped attachments alone are a prompt, as in a chat's composer.
    if (attachments.length === 0 && (!prompt || isAddress(prompt, home))) return;
    // No agent to ask: the composer's chip says Add harness (ComposerPickers), so Return adds no note.
    if (!harness) return;
    askChat(harness, prompt, project, chipModel);
  };
  submitNow.current = submit;
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
    askChat(
      harness,
      prompt && !isAddress(prompt, home) && !pairingLinkRefused(prompt) ? prompt : "",
      project,
      chipModel,
    );
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
  const focusFromRow = (event: React.MouseEvent<HTMLElement>) => {
    const input = field.current;
    if (!input || event.button !== 0 || event.target === input) return;
    // The mic and Send at the row's end (Claude Code's split) keep their own press.
    if (event.target instanceof Element && event.target.closest(".acpmux-chrome-area, .acpmux-newtab-plus")) return;
    // Keep the press from moving focus to the row; a field that had no focus gets the caret at
    // the end of its text, a focused one keeps its caret and selection.
    event.preventDefault();
    if (input.ownerDocument.activeElement === input) return;
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
  };
  const placeholder = nt("placeholder");
  // A dictation waiting for words says so in the empty field, in italic (dictation.css).
  const dictating = props.dictating === true;
  const keyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    touch();
    if (composing.current || event.nativeEvent.isComposing) return;
    const input = event.currentTarget;
    if (commandsOpen) {
      if (event.key === "Escape") {
        event.preventDefault();
        setCommandDismissed(text);
        return;
      }
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        setCommandActive(
          (commandIndex + (event.key === "ArrowDown" ? 1 : commandMatches.length - 1)) % commandMatches.length,
        );
        return;
      }
      if (event.key === "Enter" || event.key === "Tab") {
        event.preventDefault();
        pickCommand(commandMatches[commandIndex]!.command);
        return;
      }
    }
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
    const backspaced = backspacedAttachment(event, input.selectionStart === 0 && input.selectionEnd === 0, attachments);
    if (backspaced) {
      event.preventDefault();
      setAttachments((current) => current.filter((item) => item.id !== backspaced.id));
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
    if (event.key === "Tab" && plain && rows.length && current < rows.length - 1) {
      // Tab steps the open suggestions, as in Chrome's omnibox; Enter still performs the action.
      // From the last row, with none open, and Shift-Tab always, focus moves on, so the keyboard
      // can leave the field.
      event.preventDefault();
      pick(stepSelection(current, 1, rows.length));
      return;
    }
    const step = listStep(event);
    if (step && rows.length) {
      event.preventDefault();
      pick(stepSelection(current, step, rows.length));
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
  // Each folder choice takes a number; a worktree reply applies only while its choice is the latest.
  const projectChoice = useRef(0);
  const pickProject = (cwd?: string) => {
    projectChoice.current += 1;
    // A folder picked anywhere on the page (a widget card's project) replaces a saved environment.
    saved.pick(undefined);
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
  const [worktreeError, setWorktreeError] = useState<string>();
  // A saved environment's chat: on its machine, in its folder there, or on this computer in a new
  // worktree of its folder (the host makes it first; its refusal shows above the card and the
  // prompt stays in the field).
  const worktreePending = useRef(false);
  function askInEnvironment(picked: SavedEnvironment, agent: string, prompt: string, model?: string) {
    const extra = attachments.length > 0 ? attachments : undefined;
    if (picked.kind === "ssh")
      return props.onAsk(agent, prompt, picked.folder, model, undefined, extra, { peer: picked.host });
    if (!picked.worktree || !picked.folder || !props.onNewWorktree)
      return props.onAsk(agent, prompt, picked.folder, model, undefined, extra, {});
    if (worktreePending.current) return;
    worktreePending.current = true;
    setWorktreeError(undefined);
    // No chat started: the page's create buttons work again (startChat set `created`).
    const unstarted = () => {
      worktreePending.current = false;
      created.current = false;
    };
    void props.onNewWorktree(picked.folder).then(
      (folder) => {
        if (!folder) return unstarted();
        worktreePending.current = false;
        props.onAsk(agent, prompt, folder, model, undefined, extra, {});
      },
      (error: unknown) => {
        unstarted();
        setWorktreeError((error instanceof Error && error.message) || String(error));
      },
    );
  }
  const newWorktreeHere =
    props.environments && props.onNewWorktree
      ? (cwd: string) => {
          setWorktreeError(undefined);
          const choice = ++projectChoice.current;
          void props.onNewWorktree!(cwd).then(
            (folder) => {
              if (folder && choice === projectChoice.current) pickProject(folder);
            },
            (error: unknown) => {
              if (choice === projectChoice.current)
                setWorktreeError((error instanceof Error && error.message) || String(error));
            },
          );
        }
      : undefined;
  const browseProject = props.onBrowseProject
    ? () => {
        void props.onBrowseProject?.().then((cwd) => {
          if (cwd) pickProject(cwd);
        });
      }
    : undefined;
  const Chips = props.chips;
  const chooser = useRef<HTMLInputElement>(null);
  /// The Cards template (u2851): the field is a pill of its own and the chips sit under it. The
  /// split draws the chat composer's box instead.
  const pill = template === "cards" && !chatBox;

  const attachmentPicker = (
    <>
      <input
        ref={chooser}
        className="acpmux-attach-input"
        type="file"
        multiple
        hidden
        aria-label={t("composer.attach")}
        onChange={(event) => {
          const files = [...(event.currentTarget.files ?? [])];
          // Clear the chooser so picking the same file again still fires change.
          event.currentTarget.value = "";
          void attach(files, true);
        }}
      />
      <Picker
        label={t("composer.add")}
        tooltip={t("composer.addTooltip")}
        className={`acpmux-composer-plus acpmux-newtab-plus${split ? " nt-split-plus" : ""}`}
        button={<PlusIcon />}
        align="start"
        returnFocus={false}
        sections={[
          {
            choices: [{ id: "attach", name: t("composer.attach"), icon: <PaperclipIcon /> }],
            onPick: (id) => {
              if (id === "attach") chooser.current?.click();
            },
          },
        ]}
      />
    </>
  );
  // Where the chat starts: the folder Enter asks in (askFolder), picked as in the agent composer's
  // location strip; never the home ~ the tab inherited (cx-7fje0).
  const folderStrip = (
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
        {...(props.environments ? { environments: true } : {})}
        {...(newWorktreeHere ? { onNewWorktree: newWorktreeHere } : {})}
        {...(props.environments && props.onConnect ? { onConnect: props.onConnect } : {})}
        {...(saved.on
          ? {
              saved: {
                environments: saved.list,
                ...(environment ? { current: environment.id } : {}),
                onPick: (id: string) => {
                  touch();
                  saved.pick(id);
                  requestAnimationFrame(() => field.current?.focus());
                },
                onClear: () => saved.pick(undefined),
                onCreate: () => saved.edit(null),
                onEdit: (id: string) => saved.edit(saved.list.find((other) => other.id === id)),
              },
            }
          : {})}
      />
    </div>
  );
  // The SSH machines a saved environment can name (acpmux's `ssh://` peers) and each one's folders.
  const sshMachines = useMemo(
    () => (snapshot.peers ?? []).filter((peer) => snapshot.peerKinds?.[peer] === "ssh"),
    [snapshot.peers, snapshot.peerKinds],
  );
  const machineFolders = (machine: string) =>
    [
      ...new Set(
        snapshot.sessions.filter((session) => session.peer === machine && session.cwd).map((session) => session.cwd!),
      ),
    ].map((cwd) => ({ id: cwd, label: projectLabel(cwd) }));
  const environmentPanel = saved.on && saved.editing !== undefined && (
    <SavedEnvironmentPanel
      key={saved.editing?.id ?? "new"}
      {...(saved.editing ? { environment: saved.editing } : {})}
      initial={{ kind: "local", ...(askFolder ? { folder: askFolder } : {}) }}
      folders={(props.projects ?? [])
        .filter((choice) => !isAgentHome(choice.cwd))
        .map((choice) => ({ id: choice.cwd, label: choice.label }))}
      {...(props.onBrowseProject ? { onBrowse: props.onBrowseProject } : {})}
      machines={sshMachines}
      machineFolders={machineFolders}
      {...(props.onConnect ? { onConnectSSH: () => props.onConnect!("ssh") } : {})}
      onSave={saved.save}
      onRemove={saved.remove}
      onClose={() => {
        saved.edit(undefined);
        requestAnimationFrame(() => field.current?.focus());
      }}
    />
  );
  // The button row: a right-click here shows the mic hidden from its own (composerChrome.tsx);
  // this page draws no context ring.
  const pickers = (
    <ChromeArea className="acpmux-chrome-area" items={[chrome.dictation]}>
      <div className="nt-pickers" data-footer-look={plainFooter ? "plain" : undefined} onPointerDownCapture={touch}>
        {!split && attachmentPicker}
        {/* The folder Enter asks in (screenActions: the picked project, else the tab's), so a pick's
        switch is the one Enter reuses. */}
        {!split && Chips && <Chips snapshot={chipSnapshot} {...(chatFolder ? { cwd: chatFolder } : {})} />}
        <span className="acpmux-composer-actions">
          {props.accessory}
          {/* Send: a click does what Return does (a prompt, a row, or a shell command). Cards draws
              none, as Aside's New Tab: Return sends. */}
          {!pill && (
            <button
              type="button"
              className={
                text.trim() || attachments.length || reading.length
                  ? "acpmux-send acpmux-send-ready nt-send"
                  : "acpmux-send nt-send"
              }
              aria-label={t("composer.send")}
              title={t("composer.sendTooltip")}
              disabled={!text.trim() && attachments.length === 0 && reading.length === 0}
              onClick={send}
            >
              <ArrowUpIcon />
            </button>
          )}
        </span>
      </div>
    </ChromeArea>
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
      {sections.closed && widgets.has("chats") && (
        <ClosedList items={closed} onReopen={(id) => props.onJump("closed", id)} />
      )}
      {sections.chats !== "none" && !allChats && widgets.has("chats") && (
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
          {...(props.onViewChat ? { onViewOnly: props.onViewChat } : {})}
          {...(now !== undefined ? { now } : {})}
        />
      )}
    </>
  );
  // The composer: in the stage layout at the foot of the page, else at its top.
  // A model pick puts the keyboard back in the field (promptFocus.ts).
  const focusField = () => field.current?.focus();
  const composerCard = (
    <PromptFocus value={focusField}>
      {/* One card, the agent composer's (Composer.tsx; Leo 2026-10-13): the field on top, then the
          bar with the agent's model chip, the mic and Send. The location strip with the project the
          chat starts in heads it, as text over the card (ComposerContext, the composer's own; hq#1957
          composer location strip; newtab/screen.css). */}
      <div ref={setComposer} className="nt-composer" data-composer-look={look === "codex" ? "codex" : undefined}>
        {worktreeError && <WorktreeFailure error={worktreeError} onDismiss={() => setWorktreeError(undefined)} />}
        {/* Above the box: the project strip (Cards draws it under the field). */}
        {!pill && <div className="nt-above">{folderStrip}</div>}
        <div ref={setBox} className="ui-glass ui-glass-floats nt-box">
          {commandsOpen && (
            <SlashMenu
              matches={commandMatches}
              active={commandIndex}
              empty={t("composer.noMatchingCommands")}
              onHover={setCommandActive}
              onPick={pickCommand}
            />
          )}
          {/* A press anywhere on the field's row (its padding, the glyph) focuses the field, as a
            browser's address bar does; the text itself keeps its own press (caret, selection).
            Cursor rule (cx-d0d.80): the I-beam only over the text, the arrow elsewhere. */}
          {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- A pointer convenience only: the input inside is the control and takes the keyboard itself. */}
          <div className="nt-input" onMouseDown={focusFromRow}>
            {split && attachmentPicker}
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
              {...{ [WEB_SWAP_KEPT_TEXT]: "" }}
              rows={1}
              data-focus-ring="none"
              aria-label={shell ? t("composer.shell") : placeholder}
              placeholder={shell ? t("composer.shellPlaceholder") : dictating ? t("dictation.listening") : placeholder}
              data-dictation-listening={dictating && !shell ? "" : undefined}
              value={text}
              aria-controls={commandsOpen ? "acpmux-slash-menu" : "nt-rows"}
              aria-activedescendant={
                commandsOpen ? `acpmux-slash-${commandIndex}` : rows[current] ? `nt-row-${current}` : undefined
              }
              spellCheck={spellChecking && !shell}
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
            {/* Claude Code's split: the mode, model and effort went to the quiet row under the box, so
              the mic and Send end the field's row and the empty box is one line tall, as the chat
              composer's (Leo 2026-10-22: "it's also 2 lines tall for some reason"). */}
            {split && pickers}
          </div>
          {/* What was pasted on the field or dropped on the page, as a chat's composer shows it, under
            the field: the box's top is where the page anchors it, so the strip grows away from the
            text and never moves it (Leo 2026-10-19: the composer kept "going to places"). */}
          {dropHost && (
            <DropOverlay state={drop} onLanded={dropLanded} container={dropHost} landingTarget={dropLandingTarget} />
          )}
          <AttachmentStrip
            attachments={attachments}
            pending={reading}
            {...(attachError ? { error: attachError } : {})}
            codex={harness === "codex"}
            onRemove={(id) => {
              setAttachments((current) => current.filter((item) => item.id !== id));
              field.current?.focus();
            }}
            onCancel={(id) => {
              cancel(id);
              field.current?.focus();
            }}
            onRetry={retry}
            onReorder={(id, index) => setAttachments((current) => reordered(current, id, index))}
          />
          {!pill && !split && pickers}
        </div>
        {/* Claude Code's split, the chat composer's (ComposerFoot.tsx): the mode, model and effort in
            a quiet row under the box; the box keeps the prompt, the mic and Send. */}
        {split && Chips && (
          <div className="nt-foot" onPointerDownCapture={touch}>
            <ComposerFoot ref={foot}>
              <Chips snapshot={chipSnapshot} {...(chatFolder ? { cwd: chatFolder } : {})} />
            </ComposerFoot>
          </div>
        )}
        {/* Cards (u2851): the project, the agent's chips and the mic are a row under the field, as
            Aside's New Tab draws them; it steps aside while the suggestions show. */}
        {pill && (
          <div className="nt-toolbar">
            {folderStrip}
            {pickers}
          </div>
        )}
      </div>
    </PromptFocus>
  );
  // The ambient widgets (weather, machines): their own row under the field, so they never move it;
  // with the stage, whose composer sits at the foot, the row is in the stage, after the widgets. The
  // edit mode does not frame or move them; Settings turns them on and off.
  const ambient = (
    <AmbientWidgets
      {...(widgets.has("weather") && props.weather ? { weather: props.weather } : {})}
      machines={widgets.has("machines")}
      snapshot={snapshot}
      localName={props.machineName ?? t("composer.thisMac")}
      now={at}
    />
  );
  const extras = <NewTabExtras widgets={widgets} now={at} />;
  // The stage's widgets, in the user's order (`tabs.newTabWidgets.order`): Projects and Quick
  // Actions are cards (cards next to each other share a column), Recent Chats is the player and the
  // lists, as before the order; with Recent Chats off the player and the other lists come last.
  const stageCard = (widget: Exclude<MovableWidget, "chats">) =>
    widget === "projects" ? (
      <EnvironmentCard
        projects={props.projects ?? []}
        {...(envFolder ? { current: envFolder } : {})}
        noProject={none}
        {...(props.machineName ? { machineName: props.machineName } : {})}
        onPick={(cwd) => pickProject(cwd)}
        onNoProject={() => pickProject(undefined)}
        {...(browseProject ? { onBrowse: browseProject } : {})}
      />
    ) : (
      <SuggestionsCard
        attention={needsYou}
        onOpen={openCard}
        {...(props.onCreate ? { onCreate: create } : {})}
        onChat={startChat}
      />
    );
  const playerAndLists = (
    <>
      {!allChats && <NowPlayingPlayer {...(props.onNowPlaying ? { onCommand: props.onNowPlaying } : {})} />}
      {lists}
    </>
  );
  const frame = (widget: PageWidget, content: React.ReactNode) => (
    <WidgetFrame
      key={widget}
      widget={widget}
      editing={editing}
      order={order}
      className="nt-widget-slot"
      {...(onEditWidgets ? { onEdit: onEditWidgets } : {})}
    >
      {content}
    </WidgetFrame>
  );
  // The headline (off by default): "What should we work on in <project>?", its project the folder
  // Enter asks in, picked in place as the composer's strip picks it.
  const headline =
    widgets.has("greeting") &&
    frame(
      "greeting",
      <NewTabHeadline
        projects={props.projects ?? []}
        {...(askFolder ? { folder: askFolder } : {})}
        noProject={none}
        onPick={(cwd) => pickProject(cwd)}
        onNoProject={() => pickProject(undefined)}
        {...(browseProject ? { onBrowse: browseProject } : {})}
      />,
    );
  const page = (
    <ContextMenu
      className="nt-menu-host"
      items={
        onEditWidgets
          ? [
              editing.editing
                ? { id: "edit.done", label: nt("edit.done"), onSelect: () => editing.setEditing(false) }
                : { id: "edit", label: nt("edit.menu"), onSelect: () => editing.setEditing(true) },
            ]
          : []
      }
      ignore="input, textarea, [contenteditable], .acpmux-composer, .nt-popover"
      targets="own"
    >
      <div
        ref={screen}
        className="nt-screen"
        data-editing={editing.editing || undefined}
        data-shell={shell || undefined}
        data-template={template}
        data-pill={pill || undefined}
        data-all-chats={allChats || undefined}
        data-layout={stage ? "stage" : undefined}
        data-minimal={minimal || undefined}
      >
        {onEditWidgets && <WidgetEditBar editing={editing} onEdit={onEditWidgets} />}
        {stage ? (
          <>
            {/* Claude Code desktop's new-session screen (Leo 2026-10-19): the free space over the
                composer holds, centered, the environment card and the suggested actions card, then the
                recent chats; it scrolls on its own, so nothing in it ever moves the composer. */}
            <div className="nt-stage">
              {/* Minimal keeps its headline over the stage when widgets are on (Default has none). */}
              {headline}
              {stageRuns(order).map((run) =>
                run[0] === "chats" ? (
                  frame("chats", playerAndLists)
                ) : (
                  <div key={run[0]} className="nt-stage-cards">
                    {run.map((widget) => widget !== "chats" && frame(widget, stageCard(widget)))}
                  </div>
                ),
              )}
              {ambient}
              {!order.includes("chats") && playerAndLists}
            </div>
            {composerCard}
            {extras}
            {props.notice}
            {environmentPanel}
          </>
        ) : (
          <>
            {/* The headline over the composer (a widget, off by default). On Minimal it sits in a
                slot the old greeting's height, on or off, so the composer keeps the place it had
                under the greeting (screen.css .nt-headline-slot). A greeting set to false in
                cmux.json (`headlineOff`) keeps no slot while the headline is off: the composer
                stays where it sat for those who had turned the greeting off. */}
            {minimal && (headline || !props.headlineOff) ? (
              <div className="nt-headline-slot">{headline}</div>
            ) : (
              headline
            )}
            {composerCard}
            {extras}
            {ambient}
            {props.notice}
            {environmentPanel}
            {/* The create actions (cx-ag5.7, dogfood call K2): a blank terminal in the tab's folder, a
                browser tab on the new tab page, or this page as an empty chat with the agent Return asks.
                Not beside All chats: that list takes the room under the field (new-tab-scroll). */}
            {/* Cards draws no create row (u2851, as Aside's New Tab): New Terminal, New Browser Tab and
                New Chat stay in the palette and the pane's + menu. With the split too, not only the pill. */}
            {!allChats && template !== "cards" && widgets.has("actions") && (
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
        {rows.length > 0 && anchor && (
          <Popover
            open
            // The rows follow the field (Escape there and a press outside close them): the popover
            // never closes itself.
            onOpenChange={() => undefined}
            anchor={anchor}
            side={stage ? "top" : "bottom"}
            label={nt("suggestions")}
            className="nt-popover"
            initialFocus={false}
            finalFocus={false}
          >
            {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
            <div ref={attachList} className="nt-rows" id="nt-rows" role="listbox" aria-label={nt("suggestions")}>
              {rows.map((row, index) =>
                inStrip(row) ? null : (
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
                      pick(index);
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
                ),
              )}
              {rows.some(inStrip) && (
                // The create actions the rows don't list (screenModel.ts): options still, so the arrow
                // keys and the native popup reach them, drawn as one quiet line.
                // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                <div className="nt-create-strip" role="group" aria-label={nt("create.label")}>
                  {rows.map((row, index) =>
                    inStrip(row) ? (
                      <div
                        key={rowKey(row)}
                        id={`nt-row-${index}`}
                        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                        role="option"
                        tabIndex={-1}
                        aria-selected={index === current}
                        data-type={row.type}
                        className={index === current ? "nt-create-strip-item is-selected" : "nt-create-strip-item"}
                        onMouseMove={() => {
                          if (index === current) return;
                          pick(index);
                        }}
                        onMouseDown={(event) => {
                          event.preventDefault();
                          activate(row);
                        }}
                      >
                        <RowGlyph kind={rowGlyph(row)} />
                        <span className="nt-row-title">{rowTitle(nt, row)}</span>
                      </div>
                    ) : null,
                  )}
                </div>
              )}
            </div>
          </Popover>
        )}
      </div>
    </ContextMenu>
  );
  // The chips' menus open down and drop their key hints here (newTabComposer.ts).
  return <OnNewTab.Provider value={true}>{page}</OnNewTab.Provider>;
}

/// The stage's widgets in runs: next to each other, Projects and Quick Actions share a cards
/// column; Recent Chats is a run of its own.
function stageRuns(order: readonly MovableWidget[]): (readonly MovableWidget[])[] {
  const runs: MovableWidget[][] = [];
  for (const widget of order) {
    const last = runs.at(-1);
    if (widget !== "chats" && last && last[0] !== "chats") last.push(widget);
    else runs.push([widget]);
  }
  return runs;
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

/// A selection that matches no row's key.
const NO_ROW = "";

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
