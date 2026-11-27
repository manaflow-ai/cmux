import type { Dispatch, RefObject, SetStateAction } from "react";
import { agentKey } from "../../shared/agentKey";
import type { ComposerAttachment } from "../attachments";
import { askBtwQuestion } from "../btwCapability";
import type { BtwNotes } from "../aside/btwNotes";
import { callNative } from "../callNative";
import {
  CMUX_PASS_THROUGH,
  CmuxCommandRefused,
  PLACED_ACTIONS,
  cdFolder,
  cmuxCommandRefusal,
  resolveHarnessTarget,
  type CmuxCommand,
  type CmuxCommandResult,
  type HarnessTarget,
} from "../cmuxCommands";
import { commandPlace } from "../commandPlace";
import { PICKER_LABELS } from "../composerPickerModel";
import { forkToTarget, switchForks } from "../conversation/messageMenu";
import { DATE, THINKING, WORKING } from "../conversation/turns";
import type { AcpmuxDirectClient } from "../direct";
import { isFastModeOption } from "../heldOptions";
import type { SendGesture } from "../heldPrompt";
import { translate, type Translate } from "../i18n";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { postNative } from "../native";
import { openPicker, runModelCommand } from "../pickerOpeners";
import { runResume } from "../resumeCommand";
import type { RunMode } from "../sandboxRun";
import type { useSessionInfo } from "../session-info/useSessionInfo";
import type { SessionInfoSectionId } from "../session-info/sessionInfoState";
import { authText, slashLogin, type SessionAuth } from "../sessionAuth";
import type { SignIn } from "../signIn";
import { knownRefusalText } from "../transportErrors";

/// What AcpmuxPane's `handleCmuxCommand` reads from the pane (App.tsx builds it on every call).
export type CmuxCommandDeps = {
  btwNotes: BtwNotes;
  chooseProject: (
    cwd: string,
    peer?: string,
    refused?: () => void,
    accepted?: (folder: string) => void,
  ) => Promise<void>;
  commandState: (fresh: boolean) => Parameters<typeof cmuxCommandRefusal>[2];
  composerModePick: RefObject<(mode: RunMode) => void>;
  composerSnapshot: AcpmuxSnapshot;
  directClient: RefObject<AcpmuxDirectClient | undefined>;
  forkSeq: number | undefined;
  handoffTargets: HarnessTarget[];
  healthHarness: string | undefined;
  healthLocal: boolean;
  ignoreFailure: (result: Promise<unknown>) => void;
  openCloudChatWith: (start: { prompt?: string; cwd?: string }) => Promise<unknown>;
  /// The chat tab's name editor (the header's Rename); absent where there is no tab (Quick Chat).
  openRename: (() => void) | undefined;
  openSummarySection: (section: SessionInfoSectionId) => void;
  sessionAuth: SessionAuth;
  sessionInfo: ReturnType<typeof useSessionInfo>;
  setContinuing: Dispatch<SetStateAction<boolean>>;
  setStatusCardOpen: Dispatch<SetStateAction<boolean>>;
  showAllChats: () => void;
  signIn: SignIn;
  snapshot: AcpmuxSnapshot;
  t: Translate;
  turnRowsShown: AcpmuxRow[];
};

/// Shared by the chat composer and New Tab: cmux-owned slash commands never fall through to a
/// literal harness prompt. A string is an inline refusal; Composer/NewTab keep the draft intact.
export function handleCmuxCommand(
  deps: CmuxCommandDeps,
  command: CmuxCommand,
  typedArgs?: string,
  fresh = false,
  attachments: ComposerAttachment[] = [],
  gesture?: SendGesture,
): CmuxCommandResult {
  const {
    btwNotes,
    chooseProject,
    commandState,
    composerModePick,
    composerSnapshot,
    directClient,
    forkSeq,
    handoffTargets,
    healthHarness,
    healthLocal,
    ignoreFailure,
    openCloudChatWith,
    openRename,
    openSummarySection,
    sessionAuth,
    sessionInfo,
    setContinuing,
    setStatusCardOpen,
    showAllChats,
    signIn,
    snapshot,
    t,
    turnRowsShown,
  } = deps;
  const state = commandState(fresh);
  const refusal = cmuxCommandRefusal(command, typedArgs, state);
  if (refusal) return t(refusal);
  // `--on here|cloud` before a chat-starting command's arguments (commandPlace.ts); the refusal
  // above allowed only what runs. `/cd --on cloud` in a chat with no turn yet takes the folder and
  // picks Cloud in this composer, so its first Send is the composer's own Cloud start
  // (cloud.startChat, the Environment chip's pick, Auto by default). Never by default.
  const placed = commandPlace(typedArgs);
  const args = PLACED_ACTIONS.has(command.action) && "rest" in placed ? placed.rest : typedArgs;
  const toCloud = "place" in placed && placed.place === "cloud" && !state.inCloud;
  const inCloudHere = command.action === "cd" && toCloud;
  if (toCloud && command.action === "side") {
    const prompt = args?.trim();
    return openCloudChatWith(prompt ? { prompt } : {});
  }
  if (command.action === "status") {
    setStatusCardOpen(true);
    return true;
  }
  // /rename opens the tab's name editor, as ⌘R and the header's Rename do. New Tab has no chat tab.
  if (command.action === "rename") {
    if (fresh || !openRename || !snapshot.sessionId) return t("composer.cmuxUnavailable");
    openRename();
    return true;
  }
  // A bare /mcp opens Session Info on Connectors, the chat's MCP servers, now, mid-turn too: it
  // sends nothing, so nothing waits. `/mcp <args>` is the agent's own command and goes as typed;
  // New Tab has no chat whose servers to show, so there it goes to the harness as typed.
  if (command.action === "mcp") {
    if (args?.trim() || fresh) return CMUX_PASS_THROUGH;
    openSummarySection("connectors");
    return true;
  }
  // /resume: the chats search, the same page Show all chats and Cmd-K open, where an earlier chat
  // opens again where it left off; with a session id, that chat.
  // A harness other than Claude Code that lists its own /resume or /login keeps it, as before. On
  // New Tab the pane's last chat is not the one being started, so cmux's own command runs there.
  if (
    !fresh &&
    (command.action === "resume" || command.action === "login") &&
    agentKey(snapshot.summary?.family ?? snapshot.summary?.harness) !== "claude" &&
    snapshot.commands?.some((own) => own.name.toLowerCase() === command.name)
  )
    return CMUX_PASS_THROUGH;
  // `/resume <id>`: the chat that session id (its start, its transcript's path or a pasted resume
  // command) names resumes in a workspace of its own (resumeCommand.ts).
  if (command.action === "resume") return runResume(args, callNative, showAllChats, t);
  if (command.action === "login") {
    // New Tab picks its own harness and machine, which this pane's sign-in answer is not about;
    // its sign-in card covers it. The default login runs only for a chat acpmux says is here.
    if (fresh) return t("composer.cmuxLoginElsewhere");
    const harness = sessionAuth.harness ?? snapshot.summary?.harness ?? healthHarness;
    const declared = composerSnapshot.catalog.find((entry) => entry.id === harness)?.auth?.login;
    const login = slashLogin(sessionAuth, healthLocal ? declared : undefined);
    if (!login) return authText(sessionAuth, t) ?? t("composer.cmuxLoginElsewhere");
    if (login.kind === "session") signIn.loginSession?.(sessionAuth);
    else signIn.logIn(harness ?? "", login.command);
    return true;
  }
  const argument = args?.trim();
  // `/cd` is the folder chip's pick, typed: a chat with no turn yet starts in the folder, a
  // started one opens a new chat there (chooseProject). Bare, it opens the folder browser.
  if (command.action === "cd") {
    // `--on cloud`: a chat with no turn yet takes the folder, then picks Cloud; a started one
    // opens New Cloud Chat there, which checks the folder as it opens in it.
    const startedInCloud = inCloudHere && Boolean(snapshot.sessionId);
    const thenCloud = () => {
      if (inCloudHere) composerModePick.current("cloud");
    };
    if (!argument)
      return callNative<{ cwd?: string }>("project.browse").then((result) => {
        if (!result?.cwd) return;
        if (startedInCloud) return openCloudChatWith({ cwd: result.cwd });
        return chooseProject(result.cwd).then(thenCloud);
      });
    const folder = cdFolder(argument, snapshot.summary?.cwd, state.inCloud);
    if (!folder) return t("composer.cmuxCdPath");
    if (startedInCloud) return openCloudChatWith({ cwd: folder });
    const summary = snapshot.summary;
    const peer = summary?.peer || (summary?.hostKind === "cloud" ? summary.host : undefined);
    let refused = false;
    return chooseProject(folder, peer, () => {
      refused = true;
    }).then(() => {
      if (refused) throw new CmuxCommandRefused(t("composer.cmuxCdNotFolder", { folder }));
      thenCloud();
    });
  }
  // The composer sends the prompt as typed through onSend, attachments and steer included, the
  // way any other prompt goes.
  if (command.action === "passThrough") return CMUX_PASS_THROUGH;
  // `/customize …` goes to the chat's agent as the ask it stands for (customizeCommand.ts): the
  // composer and New Tab rewrite it where the prompt leaves.
  if (command.action === "customize") return CMUX_PASS_THROUGH;
  // GUI-native commands are available even when a harness does not advertise an ACP command.
  // Arguments keep the harness form useful (`/model opus`, `/plan explain`). New Tab has no chat
  // to act on yet, so there they go to the harness as typed.
  if (command.action === "model") {
    if (argument) return runModelCommand(argument) ?? CMUX_PASS_THROUGH;
    if (fresh) return CMUX_PASS_THROUGH;
    return openPicker(translate(PICKER_LABELS.model)) || CMUX_PASS_THROUGH;
  }
  if (command.action === "context") {
    if (argument || fresh) return CMUX_PASS_THROUGH;
    if (sessionInfo.reveal) {
      sessionInfo.reveal("context");
      return true;
    }
    return CMUX_PASS_THROUGH;
  }
  // A bare `/plan` with a Plan mode is the composer's own Plan/Build toggle (it remembers the mode
  // to return to); anything else goes to the harness as typed.
  if (command.action === "plan") return CMUX_PASS_THROUGH;
  if (command.action === "fast") {
    if (argument || fresh) return CMUX_PASS_THROUGH;
    const option = snapshot.summary?.configOptions?.find(isFastModeOption);
    if (option) {
      const off =
        option.options.find((choice) => /^(off|false|disabled)$/i.test(choice.value))?.value ??
        option.options[0]?.value;
      const on =
        option.options.find((choice) => /^(on|true|enabled|fast|priority)$/i.test(choice.value))?.value ??
        option.options.find((choice) => choice.value !== off)?.value;
      const next = option.currentValue === off ? on : off;
      if (next) return callNative("chat.effort", { configId: option.id, value: next });
    }
    return CMUX_PASS_THROUGH;
  }
  if (command.action === "btw") {
    const question = args?.trim();
    const sessionId = snapshot.sessionId;
    const client = directClient.current;
    if (!question || !sessionId || !client) return false;
    btwNotes.ask(
      sessionId,
      question,
      [...turnRowsShown].reverse().find((row) => ![WORKING, THINKING, DATE].includes(row.kind)),
      (question, sessionId) =>
        askBtwQuestion(client, question, sessionId, {
          inline: (question, sessionId) =>
            postNative<{ text: string }>("chat.btw.inline", { question, sessionId }).then((reply) => reply.text),
          openSide: (sessionId) => postNative("chat.sideChat", { sessionId }),
          discardSide: (sessionId) => client.discard(sessionId),
          openedMessage: () => translate("sideQuestion.opened"),
          staleMessage: () => translate("error.notOpen"),
        }),
    );
    // The pending aside keeps the whole question; typing and the main turn continue.
    return true;
  }
  if (command.action === "side") {
    // A working chat forks as it is now and keeps its turn (forkToTarget); `/side <prompt>` sends
    // the prompt to the side chat once it is open beside this one (#38042).
    const target = forkToTarget(snapshot);
    if (!target) return t("notice.forkNothingYet");
    const prompt = args?.trim();
    // The prompt's staged files go with it, in-page (callNative's own handler), as a send's do (#40066).
    return callNative("chat.side", {
      ...target,
      splitRight: true,
      ...(prompt ? { prompt } : {}),
      ...(attachments.length ? { attachments } : {}),
      ...(gesture ? { gesture } : {}),
    }).catch((error: unknown) => {
      // The side chat opened but its prompt was not sent: that refusal says so itself.
      if (error instanceof CmuxCommandRefused) throw error;
      const reason = knownRefusalText(error);
      if (!reason) console.warn("agent pane: /side did not fork", error);
      throw new CmuxCommandRefused(
        reason ? translate("notice.forkFailedReason", { reason }) : translate("notice.forkFailed"),
      );
    });
  }
  if (command.action === "fork") {
    ignoreFailure(callNative("chat.fork", { throughSeq: forkSeq }));
    return true;
  }
  if (command.action === "continue") {
    if (!args?.trim()) {
      setContinuing(true);
      return true;
    }
    const target = resolveHarnessTarget(args, handoffTargets);
    if (!target) return t("composer.cmuxContinueUnknown");
    setContinuing(false);
    // Forks in place where the chat can (`chat.switchModel`, Leo 2026-11-11: "stop asking so much
    // bullshit"); Continue In…'s review only where it cannot.
    ignoreFailure(
      callNative(switchForks(snapshot) ? "chat.switchModel" : "chat.handoff.prepare", { harness: target.id }),
    );
    return true;
  }
  return false;
}
