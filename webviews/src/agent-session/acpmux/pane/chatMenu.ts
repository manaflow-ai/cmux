import type { Dispatch, RefObject, SetStateAction } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { sayActionRefusal } from "../actionRefusal";
import { callNative } from "../callNative";
import { autoUnsupported } from "../autoSession/autoSession";
import type { useCheckpoints } from "../checkpoints/controller";
import type { CheckpointStrings } from "../checkpoints/strings";
import { cloudMachineRows, type StopWaiter, type chatCloudMachine } from "../cloudMachineMenu";
import { readUntilMoved } from "../cloudMachines";
import type { HarnessTarget } from "../cmuxCommands";
import type { SaveDocument } from "../conversation/ArtifactPanel";
import { copyText } from "../conversation/clipboard";
import { switchForks } from "../conversation/messageMenu";
import { sendPromptAgainMenu, type SendPromptAgainState } from "../conversation/sendPromptAgain";
import type { TurnActions } from "../conversation/turnActions";
import type { AcpmuxDirectClient } from "../direct";
import { CONNECT_ACTIONS, type OffloadKind } from "../environments";
import type { HandoffStrings } from "../handoff/strings";
import type { archiveRow, markUnreadRow } from "../header/archiveRow";
import { autoRows } from "../header/autoRow";
import type { avatarRows } from "../header/avatarRow";
import { HEADER_ACTIONS, guardedChatMenu, menuGroups, type ChatMenuItem } from "../header/chatHeaderToolsModel";
import { deleteChatRow, moveMachineRow } from "../header/chatRows";
import { copyRow } from "../header/copyRow";
import { forkMenuRows } from "../header/forkMenu";
import { revokeAccessRows, type chatAccessGrants } from "../header/grantsMenu";
import { headerState, type HeaderState } from "../header/headerState";
import { instructionsRow, projectFilesRow } from "../header/instructionsRow";
import { chatMini, miniRow, showInMini } from "../header/miniRow";
import { chatDetailRow } from "../header/chatDetailRow";
import type { QuickActionMode } from "../header/quickActions";
import { opensBesideRows, type sideChatRow } from "../header/sideChatRow";
import { TERMINAL_SWITCH_ACTION, moveToTerminal, terminalMoveRow, terminalSwitchRow } from "../header/terminalMoveRow";
import { wrapOutputRow } from "../header/transcriptViewRow";
import type { Translate } from "../i18n";
import { sessionLink } from "../links";
import type { AcpmuxSnapshot } from "../model";
import { hasNativeHost } from "../native";
import type { PaneNotices } from "../paneToasts";
import { sessionReplay } from "../replay/replay.experiment";
import { steerQueueExperiment } from "../steerQueue/steerQueue.experiment";

/// What AcpmuxPane's `chatMenu` reads from the pane (App.tsx builds it each time the menu is drawn).
export type ChatMenuDeps = {
  /// The pane view the chat is (paneViewStore.ts): its header state, not another view's.
  paneView?: string | null;
  accessGrants: ReturnType<typeof chatAccessGrants>;
  archive: ReturnType<typeof archiveRow>;
  avatar: ReturnType<typeof avatarRows>;
  canContinue: boolean;
  chatMachine: ReturnType<typeof chatCloudMachine>;
  checkpointLabels: CheckpointStrings;
  checkpoints: ReturnType<typeof useCheckpoints>;
  directClient: RefObject<AcpmuxDirectClient | undefined>;
  forkable: boolean;
  handoffLabels: HandoffStrings;
  handoffTargets: HarnessTarget[];
  ignoreFailure: (result: Promise<unknown>) => void;
  inspectorOpener: RefObject<HTMLElement | undefined>;
  lastForkSeq: number | undefined;
  localCwd: string | undefined;
  markUnread: ReturnType<typeof markUnreadRow>;
  moveChatToMachine: (machine: string, session: string | undefined) => void;
  moveTargets: HeaderState["moveTargets"];
  moves: HeaderState["moves"];
  newBrowser: () => void;
  newTerminal: () => void;
  notices: PaneNotices;
  offloadChat: (kind: OffloadKind, session?: string) => void;
  onOtherMachine: boolean;
  openBackgroundPanel: () => void;
  openInstructions: (cwd: string, name: string) => void;
  quick: boolean;
  readSendAgain: () => SendPromptAgainState;
  requestDelete: () => void;
  runHeaderAction: (id: string, cwd?: string, mode?: QuickActionMode) => void;
  saveDocumentNatively: SaveDocument;
  setDisplayAnchor: Dispatch<SetStateAction<HTMLElement | null>>;
  setReplaying: Dispatch<SetStateAction<string | undefined>>;
  setShareOpen: Dispatch<SetStateAction<boolean>>;
  setSteering: Dispatch<SetStateAction<boolean>>;
  sideChat: ReturnType<typeof sideChatRow>;
  snapshot: AcpmuxSnapshot;
  stopWaiter: StopWaiter;
  summary: AcpmuxSnapshot["summary"];
  t: Translate;
  toggleInspector: (open?: boolean) => boolean;
  turnActions: TurnActions;
};

/// Whether chatMenuItems has rows whatever else the chat's state is: a tab's chat always has
/// Rename and Pin, and Quick Chat's has Delete once it has a session. Only Quick Chat before its
/// session may have none, and then the header reads the rows to draw "..." disabled.
export function chatMenuHasRows(quick: boolean, sessionId: string | undefined): boolean {
  return !quick || !!sessionId;
}

/// The header's "..." menu for the pane's chat (AcpmuxPane's `chatMenu`).
export function chatMenuItems(deps: ChatMenuDeps): ChatMenuItem[] {
  const {
    paneView = null,
    accessGrants,
    archive,
    avatar,
    canContinue,
    chatMachine,
    checkpointLabels,
    checkpoints,
    directClient,
    forkable,
    handoffLabels,
    handoffTargets,
    ignoreFailure,
    inspectorOpener,
    lastForkSeq,
    localCwd,
    markUnread,
    moveChatToMachine,
    moveTargets,
    moves,
    newBrowser,
    newTerminal,
    notices,
    offloadChat,
    onOtherMachine,
    openBackgroundPanel,
    openInstructions,
    quick,
    readSendAgain,
    requestDelete,
    runHeaderAction,
    saveDocumentNatively,
    setDisplayAnchor,
    setReplaying,
    setShareOpen,
    setSteering,
    sideChat,
    snapshot,
    stopWaiter,
    summary,
    t,
    toggleInspector,
    turnActions,
  } = deps;
  const link = snapshot.sessionId ? sessionLink(snapshot.sessionId) : undefined;
  // Pause, Resume or Delete the chat's Cloud machine (cloudMachineMenu.ts), as the account's
  // machines in the composer's machine list are. A menu kept open across a chat switch runs none
  // of them: the chat it was drawn for must still be the one selected.
  const machineClient = directClient.current;
  const machineSession = snapshot.sessionId;
  const machineChatShown = () =>
    machineClient !== undefined &&
    machineClient === directClient.current &&
    machineClient.selectedSession === machineSession;
  const machine = !quick
    ? cloudMachineRows(
        chatMachine,
        snapshot.isWorking,
        t,
        (method, params) => callNative(method, params),
        (picked) => void readUntilMoved(picked),
        () => {
          const client = directClient.current;
          return { session: client?.shownSession()?.sessionId, running: client?.turnRunning() ?? false };
        },
        (session) =>
          stopWaiter.wait(() => {
            const client = directClient.current;
            return client !== undefined && client.shownSession()?.sessionId === session && client.turnRunning();
          }),
        snapshot.sessionId,
        undefined,
        machineChatShown,
      )
    : [];
  const copy = copyRow(
    { link, rows: snapshot.rows, sessionId: snapshot.sessionId },
    (text) => ignoreFailure(copyText(text)),
    t,
    () => window.cmuxAcpmuxBridge?.conversationMarkdown?.() ?? Promise.resolve(null),
    // The same Markdown through the host's save panel; a host without one copies it instead.
    () =>
      void (window.cmuxAcpmuxBridge?.conversationMarkdown?.() ?? Promise.resolve(null)).then(async (markdown) => {
        if (!markdown) return;
        const outcome = await saveDocumentNatively(markdown, snapshot.summary?.title ?? "", "markdown");
        if (outcome === "unavailable") ignoreFailure(copyText(markdown));
      }),
  );
  const again = sendPromptAgainMenu(readSendAgain(), t);
  const resend: ChatMenuItem[] = again
    ? [
        {
          key: "sendPromptAgain",
          label: again.label,
          icon: "action.retry",
          onSelect: () =>
            ignoreFailure(callNative("chat.sendPromptAgain", { sessionId: again.sessionId, rowId: again.rowId })),
        },
      ]
    : [];
  const share: ChatMenuItem | undefined =
    snapshot.sessionId && hasNativeHost()
      ? { key: "share", label: t("share.menu"), icon: "action.share", onSelect: () => setShareOpen(true) }
      : undefined;
  // Fork immediately; destination choices are a separate action and Option-click shortcut.
  const fork =
    forkable && lastForkSeq !== undefined ? forkMenuRows(lastForkSeq, () => turnActions.fork?.(lastForkSeq), t) : [];
  // New side chat, New terminal and New browser: something new beside the chat, every time.
  const opensBeside = opensBesideRows({ sideChat, quick }, { terminal: newTerminal, browser: newBrowser }, t);
  const continueIn: ChatMenuItem[] =
    snapshot.canHandoff && handoffTargets.length > 0
      ? [
          {
            key: "continue",
            label: handoffLabels.continueIn,
            icon: "agent.handoff",
            disabled: !canContinue,
            children: handoffTargets.map((target) => ({
              key: target.id,
              label: target.name,
              // In place where the chat can fork (`chat.switchModel`), no review; Continue In…'s
              // review only where it cannot.
              onSelect: () =>
                ignoreFailure(
                  callNative(switchForks(snapshot) ? "chat.switchModel" : "chat.handoff.prepare", {
                    harness: target.id,
                  }),
                ),
            })),
          },
        ]
      : [];
  const replay: ChatMenuItem[] =
    !quick && snapshot.sessionId && experimentArm(sessionReplay) === "on"
      ? [
          {
            key: "replay",
            label: t("replay.open"),
            icon: "history",
            onSelect: () => setReplaying(snapshot.sessionId),
          },
        ]
      : [];
  const steerQueueRow: ChatMenuItem[] =
    !quick && experimentArm(steerQueueExperiment) === "on"
      ? [
          {
            key: "steerQueue",
            label: t("steerQueue.open"),
            icon: "composer.steer",
            onSelect: () => setSteering(true),
          },
        ]
      : [];
  // The chat folder's CLAUDE.md or AGENTS.md, in a file tab beside the chat (a tab: not Quick Chat).
  const instructions = quick
    ? undefined
    : instructionsRow({ cwd: localCwd, family: summary?.family || summary?.harness }, openInstructions);
  // Files every chat in the folder reads: copied into it and named in that file (cx-ncc.67).
  const projectFiles = quick
    ? undefined
    : projectFilesRow({ cwd: localCwd, family: summary?.family || summary?.harness }, (cwd, name) =>
        ignoreFailure(callNative("project.addFiles", { cwd, name })),
      );
  const display = {
    key: "display",
    label: t("chatDisplay.menu"),
    onSelect: () =>
      setDisplayAnchor(
        Array.from(document.querySelectorAll<HTMLElement>(".acpmux-header-tools button")).find(
          (button) => button.getAttribute("aria-label") === t("chatMenu.open"),
        ) ?? document.querySelector<HTMLElement>(".acpmux-header-tools"),
      ),
  };
  // Messages, Normal, Thinking or Verbose for this chat, then Wrap lines (every command's output)
  // and Text & Width… under them in one submenu (header/chatDetailRow.ts): the menu is full
  // height, and a row more pushes Archive off it.
  const transcriptView = chatDetailRow(snapshot.sessionId, t, [wrapOutputRow(t), display]);
  const tools: ChatMenuItem[] = [
    transcriptView ?? { ...display, icon: "site.permission.localfonts" },
    ...replay,
    ...steerQueueRow,
    ...(instructions ? [instructions] : []),
    ...(projectFiles ? [projectFiles] : []),
    {
      key: "inspector",
      label: t("inspector.title"),
      icon: "code",
      onSelect: () => {
        inspectorOpener.current = Array.from(
          document.querySelectorAll<HTMLElement>(".acpmux-header-tools button"),
        ).find((button) => button.getAttribute("aria-label") === t("chatMenu.open"));
        toggleInspector(true);
      },
    },
    // Quick Chat's panel has no right column for it.
    ...(quick
      ? []
      : [
          {
            key: "backgroundTasks",
            label: t("backgroundTasks.title"),
            icon: "task.status.backlog",
            // A workflow's side tab would cover the panel (a full-height overlay): it closes.
            onSelect: openBackgroundPanel,
          },
        ]),
    ...(checkpoints.supported
      ? [
          {
            key: "checkpoint",
            label: checkpointLabels.createCheckpoint,
            icon: "action.review",
            onSelect: checkpoints.show,
          },
        ]
      : []),
    // Revoke Granted Access: the chat's grants, revocable with default settings (header/grantsMenu.ts).
    ...revokeAccessRows(accessGrants, t),
  ];
  // Move to machine and Delete were the title's menu rows until the title became plain text
  // (header/ThreadTitle.tsx); they live here so no action is lost. Cloud targets come from the
  // host's live MachineRegistry list and dispatch through the existing CloudMove action.
  const sessionId = snapshot.sessionId;
  const client = directClient.current;
  // A menu kept open across a chat switch never moves or deletes the chat now shown.
  const sameChat = () =>
    client !== undefined && client === directClient.current && client.selectedSession === sessionId;
  const guarded = (row: ChatMenuItem | undefined): Exclude<ChatMenuItem, "separator">[] =>
    row ? guardedChatMenu([row], sameChat).filter((item) => item !== "separator") : [];
  const setAutoSession = (auto: boolean, keepInCloud?: boolean) => {
    if (!client || !sessionId) return;
    void client
      .setAutoSession(sessionId, auto, keepInCloud)
      .catch((error: unknown) => (autoUnsupported(error) ? undefined : notices.failed(t("auto.setFailed"))));
  };
  const moveMachine = moveMachineRow(
    {
      move: moves.includes(CONNECT_ACTIONS.move),
      bringBack: moves.includes(CONNECT_ACTIONS.bringBack),
      targets: moveTargets,
    },
    {
      moveTo: (id) => moveChatToMachine(id, sessionId),
      bringBack: () => (sessionId ? offloadChat("bringBack", sessionId) : undefined),
    },
    t,
    // Auto and Keep in Cloud (header/autoRow.ts), with the chat's other Cloud rows. An acpmux that
    // does not know Auto is not an error to show: the rows are only there when it named the chat's
    // Auto state, so that answer means an older daemon took over since.
    autoRows(
      sessionId ? summary?.autoSession : undefined,
      {
        setAuto: (auto) => setAutoSession(auto),
        keepInCloud: (keep) => setAutoSession(true, keep),
      },
      t,
    ),
  );
  const remove = sessionId ? guarded(deleteChatRow(requestDelete, t)) : [];
  const moveRow = guarded(moveMachine);
  // Switch to terminal (header/terminalMoveRow.ts): a terminal runs this chat's session, so the App's Toggle
  // Terminal and Chat shows it, as the tab's right-click does; it leads the menu, as Switch to Chat leads the
  // pane's "..." on the terminal.
  const terminalSwitch = guarded(
    terminalSwitchRow(
      { switchable: headerState(paneView).terminalSwitch, native: hasNativeHost(), quick },
      () =>
        void callNative("action.run", {
          id: TERMINAL_SWITCH_ACTION,
          ...(sessionId ? { session: sessionId } : {}),
        }).catch(sayActionRefusal(notices.transient)),
      t,
    ),
  );
  // Move to Terminal (header/terminalMoveRow.ts): this pane stops running the chat, then the
  // harness's own resume runs it in a terminal and the tab closes; never while a turn runs.
  // Not on a chat a terminal already runs: Switch to terminal shows that one.
  const terminalMove = guarded(
    terminalSwitch.length
      ? undefined
      : terminalMoveRow(
          {
            sessionId,
            family: summary?.family || summary?.harness,
            agentSessionId: summary?.agentSessionId,
            local: !onOtherMachine && !(summary?.host && summary.hostKind !== "local"),
            native: hasNativeHost(),
            quick,
            watching: Boolean(summary?.watching),
            working: snapshot.isWorking,
          },
          (key) =>
            void moveToTerminal(
              key,
              {
                release: () => (client && sessionId ? client.releaseToTerminal(sessionId) : Promise.reject()),
                open: (chat) => callNative("chats.openInTerminal", { key: chat }),
                close: () => runHeaderAction(HEADER_ACTIONS.close),
                same: sameChat,
                say: notices.transient,
              },
              t,
            ),
          t,
        ),
  );
  // Quick Chat's panel is not a tab: only the chat's own actions.
  if (quick) return menuGroups(fork, continueIn, resend, copy ? [copy] : [], moveRow, tools, remove);
  // ChatGPT's order: the chat's name and pin, new chats from it, Copy, where it shows, then Archive.
  return menuGroups(
    terminalSwitch,
    [
      {
        key: "rename",
        label: t("chatMenu.rename"),
        icon: "action.edit",
        shortcutAction: HEADER_ACTIONS.rename,
        onSelect: () => runHeaderAction(HEADER_ACTIONS.rename),
      },
      {
        key: "pin",
        label: headerState(paneView).pinned ? t("chatMenu.unpin") : t("chatMenu.pin"),
        icon: "action.pin",
        shortcutAction: HEADER_ACTIONS.pin,
        onSelect: () => runHeaderAction(HEADER_ACTIONS.pin),
      },
    ],
    [...opensBeside, ...fork],
    continueIn,
    resend,
    // Share… beside Copy (Leo, 2026-11-07: "put it in the dot dot dot area"): a started chat in the app.
    [...(share ? [share] : []), ...(copy ? [copy] : [])],
    [
      {
        key: "moveRight",
        label: t("chatMenu.moveRight"),
        icon: "pane.split.right",
        shortcutAction: HEADER_ACTIONS.moveRight,
        onSelect: () => runHeaderAction(HEADER_ACTIONS.moveRight),
      },
      {
        key: "newWorkspace",
        label: t("chatMenu.newWorkspace"),
        icon: "workspace.new",
        shortcutAction: HEADER_ACTIONS.newWorkspace,
        onSelect: () => runHeaderAction(HEADER_ACTIONS.newWorkspace),
      },
      {
        key: "newWindow",
        label: t("chatMenu.newWindow"),
        icon: "app.open.external",
        shortcutAction: HEADER_ACTIONS.newWindow,
        onSelect: () => runHeaderAction(HEADER_ACTIONS.newWindow),
      },
      ...(headerState(paneView).floatingChat && snapshot.sessionId
        ? [
            {
              key: "floatingChat",
              label: t("chatMenu.floatingChat"),
              icon: "site.permission.windowmanagement",
              onSelect: () => runHeaderAction(HEADER_ACTIONS.floatingChat),
            },
          ]
        : []),
    ],
    [...moveRow, ...terminalMove, ...machine],
    tools,
    [
      ...avatar,
      ...(quick
        ? []
        : miniRow({ sessionId: snapshot.sessionId, mini: chatMini() }, (sessionId) => void showInMini(sessionId), t)),
      ...(markUnread ? [markUnread] : []),
      ...(archive ? [archive] : []),
      ...remove,
      {
        key: "close",
        label: t("chatMenu.close"),
        icon: "tab.close",
        shortcutAction: HEADER_ACTIONS.close,
        onSelect: () => runHeaderAction(HEADER_ACTIONS.close),
      },
    ],
  );
}
