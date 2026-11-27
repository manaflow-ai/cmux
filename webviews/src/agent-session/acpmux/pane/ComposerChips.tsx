import { useCallback, useRef, useState } from "react";
import { type AcpmuxSnapshot } from "../model";
import { newTabChipSnapshot } from "../newtab/chipDefaults";
import { useHarnessesPage } from "../harnesses/harnessesPage";
import { holdCloudModePick } from "../cloudModePick";
import { clearCloudAgentPick, holdCloudAgentEffort, holdCloudAgentPick, useCloudAgentPick } from "../cloudAgentPick";
import { HELD_EFFORT_ID, HELD_FAST_ID, isEffortOption, isFastModeOption } from "../heldOptions";
import { isDefaultChoice } from "../defaultChoice";
import { useDraftActionsVersion } from "../composerDraft";
import { useHarnessesListed } from "../catalog";
import { usePickerCatalog } from "../modelCatalogHost";
import { ComposerPickers } from "../ComposerPickers";
import { switchForks } from "../conversation/messageMenu";
import { useSignIn } from "../signIn";
import { callNative } from "../callNative";
import { holdModePick } from "../heldModePick";
import { TerminalPickersNote } from "../TerminalPickersNote";

/// The composer chips on the New Tab page (cx-e2aa): no chat exists yet, so a pick starts a deferred
/// switch to the shown agent in the page's project (`chat.new {deferred}`): acpmux starts the session
/// behind the page, which stays, and the pick lands on it (harnessSwitch keeps picks made while a
/// switch runs). Enter asks the same agent in the same folder, the same switch, which then shows.
export function NewTabComposerChips({
  snapshot,
  cwd,
  onAddAgent,
}: {
  snapshot: AcpmuxSnapshot;
  cwd?: string;
  onAddAgent?(): void;
}) {
  return <DefaultComposerChips snapshot={snapshot} cwd={cwd} onAddAgent={onAddAgent} startsChat />;
}

/// The chat's own composer chips, as the pane draws them under a chat (tests drive them directly).
export function ChatComposerChips({ snapshot }: { snapshot: AcpmuxSnapshot }) {
  return <DefaultComposerChips snapshot={snapshot} />;
}

/// The composer row's chips. A chat a cmux terminal runs (Toggle Terminal and Chat, `terminal`)
/// keeps Send, Stop and its attachments: each goes into that terminal's harness (acpmux
/// `hub/bridge.rs`, `hub/terminal_input.rs`). Its model, effort and mode chips cannot apply there:
/// the terminal's Claude Code or Codex runs its own and takes no change of them from outside its
/// terminal, and a pick here would start this chat's own harness (acpmux refuses that while the
/// terminal runs it). The row says where they are set instead.
export function DefaultComposerChips(props: {
  snapshot: AcpmuxSnapshot;
  cwd?: string;
  onAddAgent?(): void;
  startsChat?: boolean;
}) {
  if (!props.startsChat && props.snapshot.summary?.terminal === true) return <TerminalPickersNote />;
  return <PickerChips {...props} />;
}

function PickerChips({
  snapshot,
  cwd,
  onAddAgent,
  startsChat = false,
}: {
  snapshot: AcpmuxSnapshot;
  /// The folder a chat the chips start opens in (the New Tab page's project).
  cwd?: string;
  onAddAgent?(): void;
  /// The chips belong to a page with no chat yet: a model, mode or effort pick starts one first.
  startsChat?: boolean;
}) {
  const inFolder = startsChat ? { ...(cwd ? { cwd } : {}), deferred: true } : {};
  const harnessesPage = useHarnessesPage();
  const addAgent = onAddAgent ?? harnessesPage;
  const signIn = useSignIn();
  // acpmux has answered with its harnesses: only then can the chip say none is installed.
  const harnessesListed = useHarnessesListed();
  // Cloud picked: the agent picked for the machine (cloudAgentPick.ts) is the one the chips show and the
  // Cloud send names; this Mac starts no chat for it (cmux#51731).
  const cloudPick = useCloudAgentPick();
  // A session this Mac opened for the page (a real New Agent Chat opens one before the first send) is not
  // the one that runs: once an agent is picked for the machine, the chips keep showing that pick until the
  // first message, never the local session's agent alone (cmux#59716: the chip read just "Codex", a
  // local Codex session that had named no model or level yet).
  const onCloud =
    snapshot.startsOnCloud === true &&
    (!snapshot.summary?.sessionId || (cloudPick !== undefined && (snapshot.summary.turnCount ?? 0) === 0));
  const localSession = onCloud && cloudPick !== undefined && !!snapshot.summary?.sessionId;
  const sameAgent = snapshot.summary?.harness === cloudPick?.harness;
  const shown: AcpmuxSnapshot =
    onCloud && cloudPick
      ? {
          // The chips draw the Cloud start, which has no session yet: a local session's id, and another
          // agent's options and modes, are not its own.
          ...(localSession ? withoutSession(snapshot) : snapshot),
          summary: {
            ...snapshot.summary,
            ...(localSession ? { sessionId: "" } : {}),
            ...(localSession && !sameAgent ? { configOptions: undefined, modes: undefined } : {}),
            harness: cloudPick.harness,
            model: cloudPick.model ?? (sameAgent ? snapshot.summary?.model : undefined),
          } as AcpmuxSnapshot["summary"],
        }
      : snapshot;
  // The page's action map (chat.new, chat.mode) is installed by the connect, after the chips first
  // draw; the chips draw again when it is installed or dropped.
  useDraftActionsVersion();
  // The agent the last pick on this page started (`onHarness`): a level, mode or model picked before the
  // page's snapshot names it goes to that agent's chat, never back to the one the page showed before
  // (cmux#59716: Opus 5.5, then Medium, switched the page back to Codex).
  const pickedHarness = useRef<string | undefined>(undefined);
  // Dropped once the page names that agent itself, or has a session.
  if (snapshot.summary?.sessionId || snapshot.summary?.harness === pickedHarness.current)
    pickedHarness.current = undefined;
  // `chat.new` for the same agent and folder is the switch already running, so a second pick
  // never restarts it.
  const start = () => {
    const harness = pickedHarness.current ?? snapshot.summary?.harness;
    if (!startsChat || !harness || snapshot.summary?.sessionId) return;
    void callNative("chat.new", { harness, ...inFolder }).catch(() => undefined);
  };
  // A New Tab's permission chip is a live menu from its first frame, never the inert placeholder
  // waiting for the page's actions (Leo, 2026-11-07: "I can't click to adjust the bypass
  // permissions button there in that new tab screen"; test/newtab-machine-menu.test.ts). A pick
  // made before the connect installs `chat.mode` is held, and runs through the same chat.new and
  // chat.mode path as any other pick once it does; a later pick replaces it. The chip shows the
  // pick meanwhile (AccessMenu's optimistic mode, settled by the returned promise).
  const pickMode = (modeId: string) => {
    start();
    return callNative("chat.mode", { modeId });
  };
  // A pick before the connect is the page's (heldModePick.ts), so a first send that unmounts these
  // chips never loses it; the connect flushes it. The run reads the page's actions when it runs.
  const onMode = (modeId: string): Promise<unknown> => {
    // Cloud picked: the pick waits for the Cloud send, which starts the chat in it on the machine;
    // this Mac starts nothing for it.
    if (snapshot.startsOnCloud) {
      holdCloudModePick(shown.summary?.harness, modeId);
      return Promise.resolve();
    }
    if (!startsChat || window.cmuxAcpmuxActions?.["chat.mode"] !== undefined) return pickMode(modeId);
    return holdModePick(modeId, pickMode);
  };
  const picker = usePickerCatalog(
    snapshot.catalog,
    {
      harness: shown.summary?.harness,
      model: shown.summary?.model,
      configOptions: snapshot.summary?.configOptions,
    },
    snapshot.sessions,
  );
  const [refreshStatus, setRefreshStatus] = useState<"idle" | "fetching" | "updated" | "error">("idle");
  const refreshCatalog = useCallback(async () => {
    setRefreshStatus("fetching");
    try {
      await picker.refresh();
      setRefreshStatus("updated");
    } catch {
      setRefreshStatus("error");
      // l10n-allow: a developer error for the refresh caller; the picker shows refreshStatus, never this text.
      throw new Error("models.catalog refresh failed");
    }
  }, [picker]);
  return (
    <ComposerPickers
      snapshot={startsChat ? newTabChipSnapshot(shown, picker.catalog) : shown}
      startsChat={startsChat}
      {...(onCloud && cloudPick?.effort ? { startLevel: { harness: cloudPick.harness, value: cloudPick.effort } } : {})}
      // A New Tab pick is held whenever the chat has a harness to start (start() sends chat.new
      // first); before the page's actions are connected, `onMode` holds it until they are.
      holdsModePick={snapshot.switching !== undefined || (startsChat && !!snapshot.summary?.harness)}
      // A Cloud or other remote machine's chat starts with its first send: until then its mode pick
      // is held for that start (Leo 2026-11-01: "i couldn't even pick a mode for this kind aqua
      // sandpaper one"), and once its agent reports its modes, their menu replaces this one.
      holdsStartMode={
        (!startsChat && snapshot.origin === "remote" && !snapshot.summary?.sessionId) || snapshot.startsOnCloud === true
      }
      onModel={(modelId) => {
        const cloudHarness = onCloud ? shown.summary?.harness : undefined;
        if (cloudHarness) {
          holdCloudAgentPick({ harness: cloudHarness, model: modelId });
          return;
        }
        // A pick here is the latest: a Cloud pick made before it no longer stands for the chips, so Cloud
        // picked again shows (and starts) this agent, never the earlier one (cmux#59716, Codex to Claude).
        clearCloudAgentPick();
        start();
        void callNative("chat.model", { modelId });
      }}
      onMode={onMode}
      onEffort={(configId, value) => {
        // Cloud picked: a level is held for the Cloud send with the agent the chips show, as its model is.
        // It never starts this Mac's own agent (cmux#59716: a level picked after Opus 5.5 started a Codex
        // chat here, and the chips then showed that chat's Codex). The machine takes no Fast pick.
        if (onCloud) {
          // A level is any reasoning pick: the held id before a session, or an option that is the
          // session's effort (a profile's own id, such as `reasoning_effort`); never Fast or another option.
          const option = snapshot.summary?.configOptions?.find((candidate) => candidate.id === configId);
          const level = option
            ? isEffortOption(option)
            : !isFastModeOption({ id: configId }) && configId !== HELD_FAST_ID;
          const model = shown.summary?.model;
          if (level)
            holdCloudAgentEffort(
              shown.summary?.harness,
              value,
              model && !isDefaultChoice({ id: model }) ? model : undefined,
            );
          return;
        }
        start();
        void callNative("chat.effort", { configId, value });
      }}
      // A started chat whose host serves Continue In… but not an in-place fork carries its
      // conversation there (Continue In…'s review) rather than starting a blank chat (cmux#55750).
      onHarness={(harness, model, options) => {
        // Cloud picked: held for the Cloud send, which starts the chat on the machine in it.
        if (onCloud) {
          // The level a combo or a carried level names rides the pick (heldOptions.ts HELD_EFFORT_ID).
          const effort = options?.[HELD_EFFORT_ID];
          holdCloudAgentPick({ harness, ...(model ? { model } : {}), ...(effort ? { effort } : {}) });
          return;
        }
        clearCloudAgentPick();
        if (startsChat) pickedHarness.current = harness;
        void (
          !startsChat && snapshot.sessionId && snapshot.canHandoff && !switchForks(snapshot)
            ? callNative("chat.handoff.prepare", { harness })
            : callNative("chat.new", {
                harness,
                ...(model ? { model } : {}),
                ...(options ? { options } : {}),
                ...inFolder,
              })
        ).catch(() => undefined);
      }}
      // A started chat switches to any other harness's model (Leo 2026-10-22: "need to be able to
      // switch to different harnesses, can expose as fork"). A pick only holds it (forkHold.ts); the
      // next message forks (Leo 2026-11-06: "it should only need to necessarily fork when you enter
      // a message on that new model"), in this same pane with no review or question (Leo
      // 2026-11-11: "it should just be able to seamlesly within the same pane do stuff and stop
      // asking so much bullshit"), App.tsx `chat.switchModel`.
      {...(!startsChat && switchForks(snapshot) ? { fork: true } : {})}
      {...(cwd ? { folder: cwd } : {})}
      // Sent from the pick's own handler: the host's Enable confirmation needs the gesture.
      onHarnessEnable={(folder, id) => void callNative("chat.harness.enable", { folder, id }).catch(() => undefined)}
      // Add harness… (the picker's last row; the chip itself with no harness): the Harnesses page,
      // in place, from this click's gesture.
      {...(addAgent ? { onAddAgent: addAgent } : {})}
      {...(signIn ? { signIn } : {})}
      harnessesListed={harnessesListed}
      showPlan={false}
      pickerCatalog={picker.catalog}
      catalogRefresh={{ status: refreshStatus, date: picker.date, refresh: refreshCatalog }}
      // A prewarm hint for the direct client only: the native host has no daemon to warm.
      onHarnessHint={(harness) => void window.cmuxAcpmuxActions?.["chat.harness.hint"]?.({ harness })}
    />
  );
}

/// `snapshot` without the id of the chat the pane shows.
function withoutSession(snapshot: AcpmuxSnapshot): AcpmuxSnapshot {
  const { sessionId: _sessionId, ...rest } = snapshot;
  return rest as AcpmuxSnapshot;
}
