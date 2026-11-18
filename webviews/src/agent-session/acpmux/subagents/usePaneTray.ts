import { type RefObject, useCallback, useLayoutEffect, useMemo, useState } from "react";
import type { AcpmuxPlanEntry } from "../model";
import { openCommand, opensProcessTerminal } from "../processTerminal";
import {
  type BackgroundCommand,
  backgroundCommands,
  backgroundSection,
  type ProcessRegistry,
} from "../session-info/processes";
import type { StartedSession } from "../started/startedSessions";
import type { SummaryBackgroundTask } from "../summary/sessionSummary";
import { endedInFailure, finishedTrayItems, type TrayItem, trayItemKey, trayItems } from "./runningTray";
import type { Subagent } from "./subagentFold";
import type { SubagentTrayPlacement } from "./subagentTrayPlacement";
import { lingeringTrayItems, trayItemEnd, useTrayLinger } from "./trayLinger";
import { settleTrayExit } from "./trayMotionModel";

// The pane's tray (SubagentTray.tsx), out of App.tsx, which the React Compiler skips: its lines, what
// ended and lingers in the hat, the card's motion and its command opener. Two hooks, each called where
// App had its code, so the linger's effect and the exit's layout effect keep their places among App's.

const NO_COMMANDS: readonly BackgroundCommand[] = [];

/// A value kept while its deps are the same (`Object.is`, as `useMemo` compares them), for a value
/// made from more than its deps (a list held by its key): the compiler cannot keep such a `useMemo`.
type Kept<T> = { deps: readonly unknown[] | undefined; value: T | undefined };
const createKept = <T>(): Kept<T> => ({ deps: undefined, value: undefined });
function keptBy<T>(kept: Kept<T>, deps: readonly unknown[], make: () => T): T {
  const same =
    kept.deps !== undefined &&
    kept.deps.length === deps.length &&
    kept.deps.every((dep, index) => Object.is(dep, deps[index]));
  if (!same) {
    kept.deps = deps;
    kept.value = make();
  }
  return kept.value as T;
}

export type PaneTrayItemsInput = {
  /// Debug Settings agentPane.debug.subagentTray (runningTray.ts `useSubagentTray`).
  subagentTray: boolean;
  workflowLabsEnabled: boolean;
  /// Every subagent of the chat; a new list when one's state changes.
  chatAgents: readonly Subagent[];
  /// The background commands that run, the registry's merged with the transcript's; new on every snapshot.
  runningCommandList: readonly BackgroundCommand[];
  childSessions: readonly StartedSession[];
  isWorking: boolean;
  processRegistry: ProcessRegistry;
  transcriptTasks: readonly SummaryBackgroundTask[];
  clockOffsetMs: number | undefined;
  shownSessionId: string | undefined;
};

/// The tray's lines, and what ended and still lingers in the hat.
export function usePaneTrayItems({
  subagentTray,
  workflowLabsEnabled,
  chatAgents,
  runningCommandList,
  childSessions,
  isWorking,
  processRegistry,
  transcriptTasks,
  clockOffsetMs,
  shownSessionId,
}: PaneTrayItemsInput) {
  // The tray's lines (subagents/runningTray.ts): the subagents, the background commands
  // (session-info/processes.ts `backgroundCommands`, the registry's merged with the transcript's) and
  // the started chats that run. A new list only when what it shows changes, so streamed text never redraws the tray.
  const commandsKey = runningCommandList
    .map((task) =>
      [
        task.id,
        task.command,
        task.description ?? "",
        task.startedAt ?? "",
        task.processId ?? "",
        task.toolCallId ?? "",
      ].join("\u0000"),
    )
    .join("\u0001");
  // Labs: a workflow has its card in the transcript and its panel, never a tray row, running or ended.
  const trayAgents = useMemo(
    () => (workflowLabsEnabled ? chatAgents.filter((agent) => agent.kind !== "workflow") : chatAgents),
    [workflowLabsEnabled, chatAgents],
  );
  // runningCommandList is new on every snapshot; its key is not.
  const [keptList] = useState(createKept<TrayItem[]>);
  const trayList = keptBy(keptList, [subagentTray, trayAgents, commandsKey, childSessions, isWorking], () =>
    subagentTray ? trayItems(trayAgents, runningCommandList, childSessions, isWorking) : [],
  );
  // What ended stays in the hat a while as done, failed or stopped, then goes (subagents/trayLinger.ts;
  // Leo, 2026-11-07: "it's probably better to let them expire after a while. But the key point: after
  // a while. Okay, they, like, disappear instantly"): the subagents and started chats that ended, and
  // the background commands that ended (the registry's, with their exit and end, and the transcript's).
  // Never in the header's running count. A new list only when what ended changes, never per token.
  const endedCommandList = useMemo(
    () =>
      subagentTray
        ? backgroundCommands(processRegistry.processes, transcriptTasks, processRegistry.listed).filter(
            (command) => command.state !== "running",
          )
        : NO_COMMANDS,
    [subagentTray, processRegistry, transcriptTasks],
  );
  const endedCommandsKey = endedCommandList
    .map((task) =>
      [
        task.id,
        task.state,
        task.command,
        task.description ?? "",
        task.startedAt ?? "",
        task.endedAt ?? "",
        task.toolCallId ?? "",
        task.subagent ?? "",
      ].join("\u0000"),
    )
    .join("\u0001");
  // endedCommandList is new on every snapshot; its key is not.
  const [keptEnded] = useState(createKept<TrayItem[]>);
  const endedCommandItems = keptBy(keptEnded, [endedCommandsKey, trayAgents], (): TrayItem[] => {
    const byId = new Map(trayAgents.map((agent) => [agent.id, agent]));
    return endedCommandList.map((command) => {
      const owner = command.subagent === undefined ? undefined : byId.get(command.subagent);
      return { kind: "command", id: command.id, command, ...(owner ? { owner } : {}) };
    });
  });
  const endedTray = useMemo(
    () =>
      subagentTray
        ? [...endedCommandItems, ...finishedTrayItems(trayAgents, childSessions)].filter(
            (item) => !endedInFailure(item),
          )
        : [],
    [subagentTray, endedCommandItems, trayAgents, childSessions],
  );
  const lingerLive = useMemo(() => trayList.map(trayItemKey), [trayList]);
  const lingerEnded = useMemo(
    () => endedTray.map((item) => ({ key: trayItemKey(item), endedAt: trayItemEnd(item) })),
    [endedTray],
  );
  // The hat is open or under the pointer: nothing expires until it lets go (SubagentTray.tsx `onHold`).
  const [hatHeld, setHatHeld] = useState(false);
  // The hat could be seen (SubagentTray.tsx `onSeen`): the grace counts only while it could, so what
  // ended while the person was in another window, or the hat was tucked away, waits for them.
  const [hatSeen, setHatSeen] = useState(false);
  // On the session's clock, as the ends are stamped (a peer's may run behind or ahead of this one).
  const lingerClock = useMemo(() => ({ offsetMs: clockOffsetMs ?? 0, seen: hatSeen }), [clockOffsetMs, hatSeen]);
  const lingering = useTrayLinger(shownSessionId, lingerLive, lingerEnded, hatHeld, lingerClock);
  const trayFinished = useMemo(
    () => lingeringTrayItems(endedTray, lingering.kept, lingering.ends),
    [endedTray, lingering],
  );
  return { trayAgents, trayList, trayFinished, setHatHeld, setHatSeen };
}

/// The chat on screen as of the last render, which the card reads as it goes (`shown`), the chat
/// that last rendered without a tray (`absentIn`), and whether a tray in the last render entered.
type TrayChat = { readonly shown: { current: string | undefined }; absentIn: string | undefined; enters: boolean };
const createTrayChat = (shownSessionId: string | undefined): TrayChat => ({
  shown: { current: shownSessionId },
  absentIn: undefined,
  enters: false,
});
/// Steps `chat` to this render, `enters` included. A chat that shows again starts over. Absence
/// counts only once the chat's own rows are read: a partial snapshot during a slow switch would make
/// a tray it already had look new. The same step twice running changes nothing that shows.
///
/// It returns nothing, and its caller reads `chat.enters` after it: a call whose value the hook
/// returns is cached by the React Compiler on its arguments, and would be skipped on a render whose
/// arguments match the last committed one's, after an abandoned render stepped `chat` elsewhere
/// (App.tsx stepped its refs on every render). A call whose value goes nowhere is not cached.
function stepTrayChat(chat: TrayChat, shownSessionId: string | undefined, hasTray: boolean, read: boolean): void {
  if (chat.shown.current !== shownSessionId) chat.absentIn = undefined;
  chat.shown.current = shownSessionId;
  chat.enters = shownSessionId !== undefined && chat.absentIn === shownSessionId;
  if (!hasTray && read) chat.absentIn = shownSessionId;
}

/// What App's `counted` holds that a tray command reads when it opens.
type CommandOpenTargets = {
  summary: Parameters<typeof opensProcessTerminal>[0];
  summaryCard: { show(): void };
  sessionInfo: { reveal?: (section: ReturnType<typeof backgroundSection>) => void };
};

export type PaneTrayCardInput = {
  quick: boolean;
  freshView: boolean;
  trayList: readonly TrayItem[];
  trayFinished: readonly TrayItem[];
  hatPlan: readonly AcpmuxPlanEntry[] | undefined;
  shownSessionId: string | undefined;
  chatRead: boolean | undefined;
  trayPlacement: SubagentTrayPlacement;
  /// App's latest summary, card and Session Info, read when a command opens.
  counted: RefObject<CommandOpenTargets>;
  showToolRow: (toolCallId: string) => boolean;
};

/// Whether the tray shows, its motion, and what opens a command of it.
export function usePaneTrayCard({
  quick,
  freshView,
  trayList,
  trayFinished,
  hatPlan,
  shownSessionId,
  chatRead,
  trayPlacement,
  counted,
  showToolRow,
}: PaneTrayCardInput) {
  // A tray command opens its terminal beside the chat; where none opens (a peer's chat, or
  // a command only the transcript knows), the Bash call that started it in the transcript; with no
  // call loaded either, the summary card, which lists it, or, while the Inspector takes the card's
  // place, its section that lists it (Background tasks, a dev server's included).
  const openTrayCommand = useCallback(
    (command: BackgroundCommand) => {
      const local = opensProcessTerminal(counted.current.summary);
      void openCommand(command.toolCallId, { local, showCall: showToolRow }).then((opened) => {
        if (opened !== "none") return;
        const { summaryCard: card, sessionInfo: panel } = counted.current;
        // The section that lists it (processes.ts `backgroundSection`).
        if (panel.reveal) panel.reveal(backgroundSection([command]));
        else card.show();
      });
    },
    [counted, showToolRow],
  );
  const hasTray = !quick && !freshView && (trayList.length > 0 || trayFinished.length > 0 || hatPlan !== undefined);
  // The tray's motion (subagents/trayMotion.tsx): the chat on screen as of this render, which the
  // tray reads as it goes (it plays its exit only while its own chat still shows), and the chat that
  // last rendered without one (a tray that appears in it eases in; one a chat opens with is there).
  // Set while rendering, as the card's ref reads it when it detaches, before any effect of this hook.
  const [trayChat] = useState(() => createTrayChat(shownSessionId));
  // On every render, an abandoned one's next included (see stepTrayChat).
  stepTrayChat(trayChat, shownSessionId, hasTray, chatRead === true);
  const trayEnters = trayChat.enters;
  // A chat switch, or the tray moving to another placement (another host), is not the tray leaving:
  // its kept copy goes before the frame paints.
  useLayoutEffect(() => settleTrayExit(), [shownSessionId, trayPlacement]);
  return { hasTray, trayChat: trayChat.shown, trayEnters, openTrayCommand };
}
