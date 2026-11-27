import { type Dispatch, type RefObject, type SetStateAction } from "react";
import { type ComposerAttachment } from "../attachments";
import { callNative } from "../callNative";
import { type CloudComposeReservation } from "../cloudComposeReservation";
import { type useChatCloudEnvironment } from "../chatCloudEnvironment";
import { currentCloudPlan, readCloudPlanFresh } from "../cloudMachines";
import { cloudPlanHoldsSend } from "../cloudPlans";
import {
  cloudPageRefusal,
  cloudRunsHere,
  cloudStartSaid,
  type cloudStartFolder,
  type cloudStartKeys as makeCloudStartKeys,
  type cloudStartTeam,
  type CloudStart,
  type CloudStartAnswer,
  type cloudSendAfterCheck,
  type grantedCloudStart,
  heldPromptShown,
} from "../cloudRun";
import { type CloudSetupAction, type CloudSetupNeed, waitForCloudSetUp } from "../cloudSetup";
import { startAfterSignIn, waitForCloudSignIn, type CloudSignInWait } from "../cloudSignIn";
import { holdsDraft, promptBeforeTyped, type CloudStartDraft } from "../cloudStartCarry";
import {
  cloudStartBegun,
  cloudStartEnded,
  cloudStartPlanHeld,
  cloudStartSignedIn,
  type CloudStartProgress,
} from "../cloudStartProgress";
import { type ComposerHandle } from "../Composer";
import { restoreComposerDraft } from "../composerRestore";
import { type HarnessSwitch } from "../harnessSwitch";
import { translate } from "../i18n";
import { type AcpmuxSnapshot } from "../model";
import { type PaneNotices } from "../paneToasts";
import { type SandboxTab } from "../sandboxRun";
import { harnessLabel } from "../subagents/agentRuns";

/// AcpmuxPane's Cloud send (RFD 0046 step 2.3): the prompt that starts a chat on a Cloud machine, the
/// send held for the tab's check or the account's plan, and the start that waits on a sign-in. Plain
/// functions over the pane's state, passed in as `deps`; the pane keeps its hooks and calls these
/// through same-named closures, so each call reads that render's values as before.

/// A Cloud send held back because the account has no Cloud plan (the pane's `cloudPlanHeld`).
export type CloudPlanHeld = {
  text: string;
  attachments: ComposerAttachment[];
  start: Omit<CloudStart, "task" | "attachments">;
  fromPage: boolean;
  shown?: { text: string; attachments: ComposerAttachment[] };
};

/// The held send's state on the page (the pane's `cloudHeld`).
export type CloudHeld = "checking" | { refusal: string; prompt: string; cwd?: string };

export type SendToCloud = (
  text: string,
  attachments: ComposerAttachment[],
  start: Omit<CloudStart, "task" | "attachments">,
  fromPage?: boolean,
  heldStillShown?: boolean,
  planRead?: boolean,
) => string | boolean;

export type BeginCloudSend = (
  request: CloudStart,
  signingIn?: boolean,
  preservedDraft?: { text: string; attachments: ComposerAttachment[] },
  fromPage?: boolean,
  promptTaken?: boolean,
) => Promise<CloudStartAnswer> | undefined;

/// What the Cloud send reads and sets of AcpmuxPane: its refs, setters, render values and its own
/// same-named closures (so a call from here goes back through the pane as before).
export interface CloudSendDeps {
  cloudOfferable: boolean;
  emptyLocalChat: boolean;
  snapshot: Pick<AcpmuxSnapshot, "sessionId" | "summary">;
  newTabGeneration: number;
  sandbox: SandboxTab;
  composerHandle: RefObject<ComposerHandle | null>;
  heldBack: RefObject<{ text: string; attachments: ComposerAttachment[] }[] | undefined>;
  cloudPlanHeld: RefObject<CloudPlanHeld | undefined>;
  cloudPlanHeldTurn: RefObject<number>;
  cloudHeldOnPage: RefObject<boolean>;
  cloudStartPending: RefObject<boolean>;
  sendToCloudLatest: RefObject<SendToCloud>;
  cloudSetUpPick: RefObject<{ action: CloudSetupAction; need: CloudSetupNeed } | undefined>;
  cloudSignInWait: RefObject<CloudSignInWait | undefined>;
  cloudSignInSend: RefObject<() => Promise<CloudStartAnswer> | undefined>;
  cloudTypedDuringStart: RefObject<CloudStartDraft | undefined>;
  /// What Return queued during a start, by its key (App `queueCloudStartSend`).
  cloudStartQueued: RefObject<{ key: string; texts: string[] } | undefined>;
  lastCloudAttempt: RefObject<{ key: string; request: CloudStart } | undefined>;
  cloudStartHeld: RefObject<{ key: string; prompt: CloudStartDraft } | undefined>;
  newTabCloudSent: RefObject<boolean>;
  cloudPageDraft: RefObject<{ text: string; attachments: ComposerAttachment[] } | undefined>;
  cloudRetryFolder: RefObject<ReturnType<typeof cloudStartFolder> | undefined>;
  setCloudStart: Dispatch<SetStateAction<CloudStartProgress | undefined>>;
  setCloudHeld: Dispatch<SetStateAction<CloudHeld | undefined>>;
  setCloudLeftPage: Dispatch<SetStateAction<number | undefined>>;
  setCloudStartsEnded: Dispatch<SetStateAction<number>>;
  cloudAfterCheck: ReturnType<typeof cloudSendAfterCheck>;
  cloudEnvironment: ReturnType<typeof useChatCloudEnvironment>;
  cloudSwitchTeam: ReturnType<typeof cloudStartTeam>;
  cloudReservation: CloudComposeReservation;
  cloudStartKeys: ReturnType<typeof makeCloudStartKeys>;
  startCloud: ReturnType<typeof grantedCloudStart>;
  harnessSwitch: HarnessSwitch;
  notices: PaneNotices;
  cancelCloudSignIn: () => void;
  dropCloudPlanWait: () => void;
  runCloudHere: (expectedKey?: string) => void;
  sendHeldForPlan: (held: CloudPlanHeld) => void;
  beginCloudSend: BeginCloudSend;
}

/// The send held for the plan goes now (the plan read fresh admits it), once: the prompt taken from the composer as a
/// Send that went at once would, unless the person changed it meanwhile.
export function sendHeldForPlanWith(deps: CloudSendDeps, held: CloudPlanHeld): void {
  const { cloudPlanHeld, composerHandle, setCloudStart, sendToCloudLatest } = deps;
  cloudPlanHeld.current = undefined;
  const handle = composerHandle.current;
  const stillShown = !held.fromPage && heldPromptShown(handle?.draft(), held.shown);
  setCloudStart(undefined);
  const went = sendToCloudLatest.current(held.text, held.attachments, held.start, held.fromPage, stillShown, true);
  if (went === true && stillShown) handle?.take();
}

export function sendToCloudWith(
  deps: CloudSendDeps,
  text: string,
  attachments: ComposerAttachment[],
  start: Omit<CloudStart, "task" | "attachments">,
  fromPage = false,
  /// A held send going (`cloudAfterCheck`): whether the chat composer still shows the prompt as it
  /// was held. Edited meanwhile, the composer keeps the edit and the start takes nothing from it.
  heldStillShown?: boolean,
  /// The plan was just read fresh and does not hold this send (`cloudPlanHeld`): it goes without another read.
  planRead = false,
): string | boolean {
  const {
    cloudOfferable,
    sandbox,
    composerHandle,
    cloudAfterCheck,
    sendToCloudLatest,
    setCloudHeld,
    cloudHeldOnPage,
    cloudStartPending,
    cloudPlanHeldTurn,
    cloudPlanHeld,
    setCloudStart,
    sendHeldForPlan,
    cloudEnvironment,
    cloudSwitchTeam,
    emptyLocalChat,
    snapshot,
    cloudReservation,
    cloudStartKeys,
    beginCloudSend,
  } = deps;
  const refused = cloudPageRefusal({ offerable: cloudOfferable, checked: sandbox.checked });
  if (refused === "cloud_chat_starting") return translate("cloudStart.chatStartingHere");
  if (refused === "cloud_checking") {
    // The tab's check hasn't answered (cloudRun.ts cloudPageRefusal): this send waits for it and
    // goes by itself, the prompt held where it was typed. A read now, since the handshake's may
    // have missed its 15 s; a read that fails again is read again on its own (sandboxUnchecked).
    // The composer's text as it was held, raw (the send's text is trimmed and expanded): an
    // unchanged composer matches it exactly.
    const shownAtHold = fromPage ? undefined : composerHandle.current?.draft();
    cloudAfterCheck.hold(
      () => {
        const handle = composerHandle.current;
        const stillShown = !fromPage && heldPromptShown(handle?.draft(), shownAtHold);
        const went = sendToCloudLatest.current(text, attachments, start, fromPage, stillShown);
        if (typeof went === "string") {
          setCloudHeld({ refusal: went, prompt: text, ...(start.cwd ? { cwd: start.cwd } : {}) });
          return;
        }
        setCloudHeld(undefined);
        // The chat composer kept the prompt while the send waited (it answered false): the start
        // takes it out now, as a Send that went at once does, unless the person changed it meanwhile.
        // A page send needs nothing: the page stays locked from the hold through its start
        // (`cloudPageHeld`, `cloudStarting`), so it holds no edit the start would lose.
        if (went === true && stillShown) handle?.take();
      },
      { prompt: text, ...(start.cwd ? { cwd: start.cwd } : {}) },
    );
    cloudHeldOnPage.current = fromPage;
    setCloudHeld("checking");
    void sandbox.read();
    return false;
  }
  if (cloudStartPending.current) return false;
  // The last read says the account has no Cloud plan (`cloudMachine.list` `plan.state` `none`; `unknown` and an
  // older app's reply never hold): nothing goes yet, the prompt stays where it was typed, and the plan is read again
  // fresh (it may have been bought since, here or on the website). Still `none`: the pricing card shows in the
  // start's place, and the prompt goes by itself once the plan is on (`cloudPlanReady`). Anything else, a failed
  // read included: the send goes now.
  if (!planRead && cloudPlanHoldsSend(currentCloudPlan())) {
    const turn = ++cloudPlanHeldTurn.current;
    const held = {
      text,
      attachments,
      start,
      fromPage,
      ...(fromPage ? {} : { shown: composerHandle.current?.draft() }),
    };
    cloudPlanHeld.current = held;
    void readCloudPlanFresh().then((plan) => {
      // The card went, another chat shows, or a newer Send replaced this one: nothing to do.
      if (cloudPlanHeld.current !== held) return;
      if (cloudPlanHoldsSend(plan)) setCloudStart(cloudStartPlanHeld(`plan-held-${turn}`, text, start.cwd));
      else sendHeldForPlan(held);
    });
    return false;
  }
  // The Environment chip's pick (CLOUD_ENVIRONMENTS_ENABLED); Auto, and the flag off, name none.
  const environment = cloudEnvironment.forSend(start.environment);
  const team = cloudSwitchTeam.forSend();
  const unreserved: CloudStart = {
    task: text,
    attachments,
    ...start,
    ...(environment ? { environment } : {}),
    ...(team ? { team } : {}),
    // The empty chat this start replaces: the host closes this tab with it once the Cloud chat opens.
    ...(emptyLocalChat && snapshot.sessionId ? { replacesChat: snapshot.sessionId } : {}),
  };
  // The compose's warm machine goes only with the Send it first went with (or that Send's retry,
  // the same start key): after a refused start, another prompt from this page would be refused
  // by the platform as `409 reservation.bound` (cloudComposeReservation.ts `handoff`).
  const reservationKey = cloudReservation.handoff(environment, cloudStartKeys.keyFor(unreserved));
  const request: CloudStart = { ...unreserved, ...(reservationKey ? { reservationKey } : {}) };
  // A page's send leaves the page: its draft comes back in the chat composer, compared there.
  const preserved = fromPage || heldStillShown === false ? undefined : composerHandle.current?.draft();
  const started = beginCloudSend(request, false, preserved, fromPage);
  // A composer's send leaves the composer open and empty, as a local send does: the prompt shows
  // as the message (CloudStartView) and comes back if the start fails (`cloudStartHeld`).
  return Boolean(started) && !fromPage;
}

export function beginCloudSendWith(
  deps: CloudSendDeps,
  request: CloudStart,
  signingIn = false,
  preservedDraft?: { text: string; attachments: ComposerAttachment[] },
  fromPage = false,
  /// A sign-in's resend took the prompt out of the composer (`cloudSignInSend`).
  promptTaken = false,
): Promise<CloudStartAnswer> | undefined {
  const {
    cloudStartKeys,
    setCloudStart,
    startCloud,
    cancelCloudSignIn,
    cloudSetUpPick,
    cloudSignInWait,
    dropCloudPlanWait,
    cloudSignInSend,
    composerHandle,
    cloudTypedDuringStart,
    cloudStartQueued,
    beginCloudSend,
    lastCloudAttempt,
    cloudStartPending,
    cloudStartHeld,
    newTabCloudSent,
    cloudPageDraft,
    setCloudLeftPage,
    newTabGeneration,
    snapshot,
    cloudSwitchTeam,
    setCloudStartsEnded,
    heldBack,
    runCloudHere,
    cloudReservation,
    cloudRetryFolder,
    harnessSwitch,
    notices,
  } = deps;
  const { task: text, ...start } = request;
  // A retry of the same start reuses its first key, so the host reaches the machine it made (#33493).
  const key = cloudStartKeys.keyFor(request);
  // Signed in: the start goes again, on the click the host kept, only if this page still waits for it.
  const again = () => {
    // The browser is done: the card leaves its waiting for sign-in state for the normal start.
    setCloudStart((current) => cloudStartSignedIn(current, key));
    return startCloud({ ...request, signedIn: true }, key);
  };
  let signIn: CloudSignInWait | undefined;
  let setUpNeed: CloudSetupNeed | undefined;
  if (signingIn) {
    // One sign-in at a time: a newer one ends the wait on an older one.
    cancelCloudSignIn();
    const pick = cloudSetUpPick.current;
    cloudSetUpPick.current = undefined;
    setUpNeed = pick?.need;
    signIn = pick ? waitForCloudSetUp(callNative, key, pick.action, pick.need) : waitForCloudSignIn(callNative, key);
    cloudSignInWait.current = signIn;
  }
  const wait = signIn;
  const started = wait
    ? startAfterSignIn(wait, () => cloudSignInWait.current === wait, again)
    : startCloud(request, key);
  // Another Return while a start waits starts nothing, and the card keeps that start.
  if (!started) return undefined;
  // A start went: no prompt held for the plan may go again after it (the pricing card's wait ends with it).
  dropCloudPlanWait();
  // What the chat composer holds for this start: the page's draft once it is put back there.
  let expectedDraft = preservedDraft;
  cloudSignInSend.current = () => {
    // The browser may stay open for minutes. If the person edits this prompt meanwhile,
    // leave the edited draft in place rather than starting Cloud with the stale request.
    const shown = composerHandle.current?.draft();
    // What was typed during the failed start, after the prompt, is not an edit of the prompt.
    const typed = cloudTypedDuringStart.current;
    const draft = shown && typed ? (promptBeforeTyped(shown, typed)?.prompt ?? shown) : shown;
    const expected = expectedDraft ?? { text, attachments: request.attachments ?? [] };
    const sameAttachments =
      draft === undefined ||
      (draft.attachments.length === expected.attachments.length &&
        draft.attachments.every((attachment, index) => attachment.id === expected.attachments[index]?.id));
    if (draft !== undefined && (draft.text !== expected.text || !sameAttachments)) {
      const answer: CloudStartAnswer = {
        ok: false,
        code: "cloud_prompt_changed",
        message: "Your prompt changed while you were signing in. Send the updated prompt to Cloud.",
      };
      setCloudStart((current) => cloudStartEnded(current, key, answer));
      return Promise.resolve(answer);
    }
    // The first send's compose reservation was handed off with it; the resumed send asks for none.
    const { reservationKey: _spentReservation, ...resumed } = request;
    // The prompt is the start's message again, as on the first Send: it leaves the composer, and
    // what was typed after it (a failed start's) stays, so the composer holds only new text while
    // the start runs. A failed or cancelled start puts the prompt back in front of it.
    const handle = composerHandle.current;
    const taken = handle !== undefined && handle !== null && draft !== undefined;
    if (taken) {
      handle.take();
      if (typed && shown && promptBeforeTyped(shown, typed)) handle.restore(typed.text, typed.attachments);
    }
    cloudTypedDuringStart.current = undefined;
    return beginCloudSend(resumed, true, expected, false, taken);
  };
  lastCloudAttempt.current = { key, request };
  cloudStartPending.current = true;
  cloudTypedDuringStart.current = undefined;
  // The composer's own Send empties the composer, and a sign-in's resend takes the prompt out
  // (`promptTaken`); a page's send leaves the page, whose draft comes back as `cloudPageDraft`.
  cloudStartHeld.current =
    !fromPage && preservedDraft && (!signingIn || promptTaken) ? { key, prompt: preservedDraft } : undefined;
  if (fromPage) {
    newTabCloudSent.current = true;
    // The prompt as sent, for a page that leaves no draft of its own (a prefilled location it
    // counts as untyped); the page's own draft, if it hands one over, replaces it.
    cloudPageDraft.current = { text, attachments: request.attachments ?? [] };
    setCloudLeftPage(newTabGeneration);
  }
  // A `cloud.signIn` waits on the browser first: the card says so, not "starting".
  setCloudStart(
    cloudStartBegun(
      key,
      text,
      start.cwd,
      start.harness ? harnessLabel(start.harness) : undefined,
      start.home,
      signingIn,
      setUpNeed,
      start.harness
        ? {
            harness: start.harness,
            ...(start.model ? { model: start.model } : {}),
            over: { harness: snapshot.summary?.harness, model: snapshot.summary?.model },
          }
        : undefined,
    ),
  );
  void started.then((answer) => {
    cloudStartKeys.ended(request, answer);
    cloudSwitchTeam.ended(answer);
    cloudStartPending.current = false;
    if (wait && cloudSignInWait.current === wait) cloudSignInWait.current = undefined;
    setCloudStartsEnded((count) => count + 1);
    // A page's draft goes back to the chat composer unless the chat opened on its machine.
    const pageDraft = cloudPageDraft.current;
    cloudPageDraft.current = undefined;
    newTabCloudSent.current = false;
    // The prompt the composer's Send took out (`cloudStartHeld`), for a start that ended here.
    const held = cloudStartHeld.current?.key === key ? cloudStartHeld.current.prompt : undefined;
    if (held) cloudStartHeld.current = undefined;
    // What Return queued during this start: the started chat took it with its first prompt.
    const queued = cloudStartQueued.current?.key === key ? cloudStartQueued.current.texts : undefined;
    if (queued) cloudStartQueued.current = undefined;
    if (!answer.ok || cloudRunsHere(answer)) {
      // Not opened on its machine: the host lets go of the queued messages, and they come back in
      // this composer, in front of what was typed since and after the prompt.
      if (queued) {
        void callNative("chat.cloudStartQueue", { text: "" }).catch(() => undefined);
        restoreComposerDraft(composerHandle, heldBack, queued.join("\n\n"), []);
      }
      // What was typed meanwhile is still in this composer, after the prompt that comes back in
      // front of it.
      const back = pageDraft ?? held;
      if (back) {
        const typed = composerHandle.current?.draft();
        restoreComposerDraft(composerHandle, heldBack, back.text, back.attachments);
        if (holdsDraft(typed)) cloudTypedDuringStart.current = typed;
      }
      if (pageDraft) expectedDraft = pageDraft;
    }
    if (!answer.ok && answer.code === "cloud_sign_in_cancelled") {
      // The person left Cloud while signing in: the prompt stays in the composer for their new pick.
      setCloudStart((current) => (current?.key === key ? undefined : current));
      return;
    }
    if (cloudRunsHere(answer)) {
      // The cap card's Run on This Mac: the prompt still in the composer goes to a chat here once the mode is.
      runCloudHere(key);
      return;
    }
    // A folder the host refused before binding the compose's reservation: that machine is given back now.
    if (!answer.ok && answer.code === "cloud_folder_too_big" && request.reservationKey)
      cloudReservation.returned(request.reservationKey);
    if (answer.ok) {
      cloudRetryFolder.current = undefined;
      // The chat opened on its machine: a pick's local session on this page (pickOnlyChat) is nobody's now.
      harnessSwitch.cancel();
    }
    setCloudStart((current) => cloudStartEnded(current, key, answer));
    if (!answer.ok && !cloudStartSaid(answer))
      notices.transient(translate("composer.offloadNotRun", { action: translate("composer.cloud") }));
  });
  return started;
}
