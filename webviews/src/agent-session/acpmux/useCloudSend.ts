import { useEffect, useEffectEvent, useInsertionEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { ComposerAttachment } from "./attachments";
import { callNative } from "./callNative";
import { setupConnect } from "./claudeConnect";
import { reservedCloudCall, type CloudComposeReservation } from "./cloudComposeReservation";
import type { useChatCloudEnvironment } from "./CloudEnvironmentChip";
import { currentCloudPlan, readCloudPlanFresh } from "./cloudMachines";
import { createCloudPlanSubscribe } from "./cloudPlanSubscribe";
import { cloudPlanHoldsSend } from "./cloudPlans";
import {
  cloudFolderGrants,
  cloudPageRefusal,
  cloudRunsHere,
  cloudSendAfterCheck,
  cloudStartFolder,
  cloudStartKeys as makeCloudStartKeys,
  cloudStartSaid,
  cloudStartTeam,
  grantedCloudStart,
  heldPromptShown,
  makeCloudSignInRetry,
  type CloudStart,
  type CloudStartAnswer,
} from "./cloudRun";
import { retryWithSetUpPick, waitForCloudSetUp, type CloudSetupAction, type CloudSetupNeed } from "./cloudSetup";
import { startAfterSignIn, waitForCloudSignIn, type CloudSignInWait } from "./cloudSignIn";
import { holdsDraft, promptBeforeTyped, type CloudStartDraft } from "./cloudStartCarry";
import {
  cloudStartBegun,
  cloudStartEnded,
  cloudStartPlanHeld,
  cloudStartSignedIn,
  cloudStartStalled,
  watchCloudStartStall,
  type CloudStartProgress,
} from "./cloudStartProgress";
import type { ComposerHandle } from "./Composer";
import { restoreComposerDraft } from "./composerRestore";
import { setRef } from "./heldFlag";
import { translate } from "./i18n";
import type { PaneNotices } from "./paneToasts";
import type { SandboxTab } from "./sandboxRun";
import { harnessLabel } from "./subagents/agentRuns";

/// A function slot, set after commit or in a handler, whose `call` runs what it holds when called: a "latest" ref
/// that the store and the retry made once (useState) and the Connect row (useMemo) can take during render, which a
/// ref's `current` read in their closures is not to the compiler.
function latestCall<A extends unknown[], R>(initial: (...args: A) => R) {
  let current = initial;
  return {
    set(fn: (...args: A) => R): void {
      current = fn;
    },
    call: (...args: A): R => current(...args),
  };
}

/// What the pane hands the Cloud send (App.tsx): the tab's run mode and check, where Cloud is offered,
/// the composer, and the pane's own parts of a view change (another chat, another New Tab).
export type CloudSendPane = {
  sandbox: SandboxTab;
  /// `sandbox`'s mode, check and unread state as this render read them (the effects' deps).
  sandboxMode: SandboxTab["mode"];
  sandboxChecked: boolean;
  sandboxUnread: boolean;
  sessionId: string | undefined;
  emptyLocalChat: boolean;
  cloudOffered: boolean;
  cloudOfferable: boolean;
  newTabGeneration: number;
  cloudReservation: CloudComposeReservation;
  cloudEnvironment: ReturnType<typeof useChatCloudEnvironment>;
  cloudFolderGrant: ReturnType<typeof cloudFolderGrants>;
  composerHandle: { current: ComposerHandle | null };
  heldBack: { current: { text: string; attachments: ComposerAttachment[] }[] | undefined };
  runModePicked: { current: boolean };
  notices: PaneNotices;
  /// The pane's own resets when another chat or New Tab shows, before and after the Cloud send's.
  viewReset: { before: () => void; after: () => void };
};

/// Starting a new chat on Cloud and sending to it (cloudRun.ts): the first send goes to the host, which opens the
/// chat on a Cloud machine and closes this tab; the start's card (CloudStartView) shows meanwhile, with its sign-in,
/// set-up, plan and retry ways on. Moved out of App.tsx whole, its effects in their order there.
export function useCloudSend({
  sandbox,
  sandboxMode,
  sandboxChecked,
  sandboxUnread,
  sessionId,
  emptyLocalChat,
  cloudOffered,
  cloudOfferable,
  newTabGeneration,
  cloudReservation,
  cloudEnvironment,
  cloudFolderGrant,
  composerHandle,
  heldBack,
  runModePicked,
  notices,
  viewReset,
}: CloudSendPane) {
  /// A Cloud start is out (the host answers once the chat opens, minutes for a new machine): the
  /// folder default changes nothing meanwhile, so the prompt it holds never turns into a local send.
  const cloudStartPending = useRef(false);
  /// A Cloud send held back because the account has no Cloud plan (`sendToCloud`): what it was, and the composer's
  /// draft as it was held (unchanged, the start takes it out once it goes). Its turn keys the held card.
  const cloudPlanHeld = useRef<
    | {
        text: string;
        attachments: ComposerAttachment[];
        start: Omit<CloudStart, "task" | "attachments">;
        fromPage: boolean;
        shown?: { text: string; attachments: ComposerAttachment[] };
      }
    | undefined
  >(undefined);
  const cloudPlanHeldTurn = useRef(0);
  /// The pricing card's Subscribe (cloudPlanSubscribe.ts): back from the browser with the plan on, the held send or
  /// the refused start goes again, once (`cloudPlanReady`, set after each commit).
  const [cloudPlanReady] = useState(() => latestCall<[], void>(() => undefined));
  const [cloudPlanStore] = useState(() => createCloudPlanSubscribe({ onReady: cloudPlanReady.call }));
  /// The pricing card went (Not now, Run on This Mac, another chat or place): nothing waits on the plan any more.
  const dropCloudPlanWait = () => {
    cloudPlanHeld.current = undefined;
    cloudPlanStore.reset();
  };
  /// The cap card answered Run on This Mac (cloudRunsHere): the prompt sends here once the mode switched.
  const runHereSend = useRef(false);
  /// Counts the Cloud starts that ended, so the folder default looks again once one has.
  const [cloudStartsEnded, setCloudStartsEnded] = useState(0);
  const [startCloud] = useState(() =>
    grantedCloudStart(reservedCloudCall(callNative, cloudReservation), cloudFolderGrant),
  );
  const [cloudStartKeys] = useState(() => makeCloudStartKeys());
  const [cloudStart, setCloudStart] = useState<CloudStartProgress>();
  const [cloudSignInSend] = useState(() => latestCall<[], Promise<CloudStartAnswer> | undefined>(() => undefined));
  /// The card retries its preserved request once; native keeps the click across browser auth.
  const [cloudSignInRetry] = useState(() => makeCloudSignInRetry(cloudSignInSend.call));
  /// The sign-in a start waits on (cloudSignIn.ts): leaving Cloud (another mode, chat or tab) withdraws it.
  const cloudSignInWait = useRef<CloudSignInWait | undefined>(undefined);
  /// Set up Cloud's button (cloudSetup.ts): the next sign-in resend waits on that way in instead of the
  /// account sign-in, then the start goes again on the click the host kept.
  const cloudSetUpPick = useRef<{ action: CloudSetupAction; need: CloudSetupNeed } | undefined>(undefined);
  const cancelCloudSignIn = () => {
    const wait = cloudSignInWait.current;
    cloudSignInWait.current = undefined;
    wait?.withdraw();
  };
  /// The last accepted first send, retained so choosing This Mac after a refusal can
  /// explicitly finish its Cloud key just as the native cap-card answer does.
  const lastCloudAttempt = useRef<{ key: string; request: CloudStart } | undefined>(undefined);
  /// A Cloud start is out. The composer stays open (Leo, 2026-11-09: "I can't click into the
  /// composer at all to, like potentially type other stuff while it's doing that initial load
  /// situation"), but sends nothing until the start ends. On success the host closes this tab and
  /// opens the chat with the sent prompt (#28686); the composer holds only what was typed after the
  /// Send (`cloudStartHeld` took the prompt out), which goes to the host at once as the tab's unsent
  /// text (Composer `onUnsentDraft`), and the host seeds the started chat's composer with it as a
  /// draft (CloudStartChat `openUploaded`). On failure the prompt comes back in front of it. A start
  /// the host has said nothing about for minutes (cloudStartProgress.ts `CLOUD_START_STALL_MS`)
  /// stalled: the card says so, and the start is still out.
  const cloudStarting = cloudStart?.state === "starting";
  /// Nothing that starts a chat goes from this tab while a Cloud start is out, stalled or not: if it
  /// still opens its chat, the host closes this tab, with a chat started here in it.
  const cloudSendHeld = cloudStarting;
  useEffect(
    () => watchCloudStartStall(cloudStart, (key) => setCloudStart((current) => cloudStartStalled(current, key))),
    [cloudStart],
  );
  /// The same, for dictation's recording (below), whose callbacks are made once.
  const cloudStartingNow = useRef(false);
  useInsertionEffect(() => {
    cloudStartingNow.current = cloudStarting;
  });
  /// The prompt a Cloud start took out of the composer (it shows as the message, with the start under
  /// it, as a local send's does), by its start's key: a failed start puts it back. Set only where the
  /// prompt was taken out (the composer's Send, a sign-in's resend), so nothing reads the prompt off
  /// the composer's text.
  const cloudStartHeld = useRef<{ key: string; prompt: CloudStartDraft } | undefined>(undefined);
  /// What was typed during a start that failed, now after its prompt in the composer: Retry and Run
  /// on This Mac send the prompt alone and leave this in the composer (`sendStartPrompt`).
  const cloudTypedDuringStart = useRef<CloudStartDraft | undefined>(undefined);
  /// Sends the failed start's prompt (Retry, Run on This Mac) as Return would. What was typed during
  /// the start stays in the composer after it and never goes with it, while the composer still holds
  /// that prompt and that text (`promptBeforeTyped`); once the person changed it, what shows goes.
  const sendStartPrompt = () => {
    const handle = composerHandle.current;
    const typed = cloudTypedDuringStart.current;
    cloudTypedDuringStart.current = undefined;
    const split = handle && typed ? promptBeforeTyped(handle.draft(), typed) : undefined;
    if (!handle || !split) return void handle?.send();
    handle.take();
    handle.restore(split.prompt.text, split.prompt.attachments);
    // The composer sends what it rendered: send once the prompt alone has (the effect below).
    startPromptSend.current = { typed: split.typed, sent: false };
    setStartPromptSends((count) => count + 1);
  };
  /// `sendStartPrompt`'s two steps, each after the composer rendered the last: the prompt alone goes,
  /// then the typed text comes back after whatever the send left.
  const startPromptSend = useRef<{ typed: CloudStartDraft; sent: boolean } | undefined>(undefined);
  const [startPromptSends, setStartPromptSends] = useState(0);
  useEffect(() => {
    const step = startPromptSend.current;
    const handle = composerHandle.current;
    if (!step || !handle) return;
    if (!step.sent) {
      step.sent = true;
      handle.send();
      setStartPromptSends((count) => count + 1);
      return;
    }
    startPromptSend.current = undefined;
    handle.restore(step.typed.text, step.typed.attachments, true);
  }, [startPromptSends, composerHandle]);
  /// A Cloud send from the New Tab page opens the chat at once, as a local send does (Leo, 2026-11-04:
  /// "i should never be seeing this it should just insta send me to a new chat just like local"): the
  /// page goes for this visit (its generation), and the chat view shows the sent message with the
  /// start under it (CloudStartView) until the host opens the chat on its machine.
  const [cloudLeftPage, setCloudLeftPage] = useState<number>();
  /// The page's draft as it went (leaveNewTabDraft): the chat composer gets it back when the start
  /// fails or the cap card runs it on this Mac, so the prompt is never lost with the page.
  const newTabCloudSent = useRef(false);
  const cloudPageDraft = useRef<{ text: string; attachments: ComposerAttachment[] } | undefined>(undefined);
  /// The same transition as the native cap card's Run on This Mac answer: keep the
  /// failed Cloud prompt in the composer, change its destination and send it once.
  const runCloudHere = (expectedKey?: string) => {
    if (expectedKey === undefined && cloudStart?.state === "failed") {
      const previous = lastCloudAttempt.current;
      if (previous?.key === cloudStart.key)
        cloudStartKeys.ended(previous.request, { ok: false, code: "run_on_this_mac" });
      lastCloudAttempt.current = undefined;
    }
    cloudSignInRetry.reset();
    if (expectedKey === undefined) dropCloudPlanWait();
    setCloudStart((current) => (expectedKey && current?.key !== expectedKey ? current : undefined));
    setRef(runModePicked, true);
    runHereSend.current = true;
    sandbox.setMode("persistent");
  };
  /// The folder the latest Cloud send named (the card's "Start without a folder", or its project): Retry
  /// repeats this exact folder, even when a New Tab pick changed from project A to project B.
  const cloudRetryFolder = useRef<ReturnType<typeof cloudStartFolder> | undefined>(undefined);
  const dismissCloudFailure = () => {
    cloudRetryFolder.current = undefined;
    dropCloudPlanWait();
    setCloudStart(undefined);
  };
  /// Set up Cloud's button: its way in runs on this Mac, and the prompt goes again once a connection
  /// serves the model (the sign-in resend, `cloudSignInSend`), with no retyping.
  const setUpCloud = (action: CloudSetupAction) => {
    const need = cloudStart?.state === "failed" ? cloudStart.cloudSetup : undefined;
    if (!need) return;
    // The resend takes the pick at once (`beginCloudSend`); a retry that sent nothing (one already out
    // or resumed, an edited prompt, a reset) leaves none, so a later Sign in signs in.
    void retryWithSetUpPick(cloudSetUpPick, { action, need }, cloudSignInRetry);
  };
  /// The model picker's Connect row (claudeConnect.ts `setupConnect`) while this chat's Cloud start
  /// waits for a connection: shown only for the family the host's Set up Cloud need names, so a local
  /// chat, or a Cloud one a connection serves, never shows it. Connect runs the card's first button.
  const [setUpCloudNow] = useState(() => latestCall<[CloudSetupAction], void>(() => undefined));
  useEffect(() => {
    setUpCloudNow.set(setUpCloud);
  });
  const cloudSetupNeed = cloudStart?.state === "failed" ? cloudStart.cloudSetup : undefined;
  const cloudSetupWaiting = cloudStart?.signingIn === true;
  const modelConnect = useMemo(
    () => setupConnect(cloudSetupNeed, cloudSetupWaiting, setUpCloudNow.call),
    [cloudSetupNeed, cloudSetupWaiting, setUpCloudNow],
  );
  /// Set up Cloud's Not now: a wait still out is withdrawn (the start then ends here), else the card goes.
  const dismissCloudSetUp = () => (cloudStart?.signingIn ? cancelCloudSignIn() : dismissCloudFailure());
  /// The plan card's Switch to <team>: the next Cloud send carries the team, and the host switches to it
  /// (the team picker's switch) before it starts, under the same click.
  const [cloudSwitchTeam] = useState(() => cloudStartTeam());
  /// The Cloud send that waits on the tab's check (cloudRun.ts cloudSendAfterCheck), while it waits.
  const [cloudAfterCheck] = useState(() => cloudSendAfterCheck());
  /// The held send's state on the page: waiting on the check, or the refusal it came back with
  /// (and the prompt, for its New Cloud chat action).
  const [cloudHeld, setCloudHeld] = useState<"checking" | { refusal: string; prompt: string; cwd?: string }>();
  const cloudWaitsForCheck = cloudHeld === "checking";
  /// The held send came from the New Tab page: the page locks while it waits, as during a start,
  /// so the send that goes is what the page shows. A check that fails (Check again) drops a page's
  /// held send and unlocks the page, its prompt still in it.
  const cloudHeldOnPage = useRef(false);
  /// `cloudHeldOnPage` as the render reads it: set with it, in the same update as the hold's `setCloudHeld`.
  const [heldOnPage, setHeldOnPage] = useState(false);
  const cloudPageHeld = cloudWaitsForCheck && heldOnPage && !sandboxUnread;
  const sendToCloudLatest = useRef<typeof sendToCloud>(() => false);
  /// The send held for the plan goes now (the plan read fresh admits it), once: the prompt taken from the composer as a
  /// Send that went at once would, unless the person changed it meanwhile.
  const sendHeldForPlan = (held: NonNullable<typeof cloudPlanHeld.current>) => {
    cloudPlanHeld.current = undefined;
    const handle = composerHandle.current;
    const stillShown = !held.fromPage && heldPromptShown(handle?.draft(), held.shown);
    setCloudStart(undefined);
    const went = sendToCloudLatest.current(held.text, held.attachments, held.start, held.fromPage, stillShown, true);
    if (went === true && stillShown) handle?.take();
  };
  const beginCloudSend = (
    request: CloudStart,
    signingInArg?: boolean,
    preservedDraft?: { text: string; attachments: ComposerAttachment[] },
    fromPageArg?: boolean,
    /// A sign-in's resend took the prompt out of the composer (`cloudSignInSend`).
    promptTakenArg?: boolean,
  ): Promise<CloudStartAnswer> | undefined => {
    const signingIn = signingInArg ?? false;
    const fromPage = fromPageArg ?? false;
    const promptTaken = promptTakenArg ?? false;
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
    cloudSignInSend.set(() => {
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
    });
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
      if (!answer.ok || cloudRunsHere(answer)) {
        // Not opened on its machine: what was typed meanwhile is still in this composer, after the
        // prompt that comes back in front of it.
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
      if (answer.ok) cloudRetryFolder.current = undefined;
      setCloudStart((current) => cloudStartEnded(current, key, answer));
      if (!answer.ok && !cloudStartSaid(answer))
        notices.transient(translate("composer.offloadNotRun", { action: translate("composer.cloud") }));
    });
    return started;
  };
  const sendToCloud = (
    text: string,
    attachments: ComposerAttachment[],
    start: Omit<CloudStart, "task" | "attachments">,
    fromPageArg?: boolean,
    /// A held send going (`cloudAfterCheck`): whether the chat composer still shows the prompt as it
    /// was held. Edited meanwhile, the composer keeps the edit and the start takes nothing from it.
    heldStillShown?: boolean,
    /// The plan was just read fresh and does not hold this send (`cloudPlanHeld`): it goes without another read.
    planReadArg?: boolean,
  ): string | boolean => {
    const fromPage = fromPageArg ?? false;
    const planRead = planReadArg ?? false;
    const refused = cloudPageRefusal({ offerable: cloudOfferable, checked: sandbox.checked });
    if (refused === "cloud_chat_starting") return translate("cloudStart.chatStartingHere");
    if (refused === "cloud_checking") {
      // The tab's check hasn't answered (cloudRun.ts cloudPageRefusal): this send waits for it and
      // goes by itself, the prompt held where it was typed. A read now, since the handshake's may
      // have missed its 15 s; a read that fails again shows Check again (sandboxUnchecked).
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
      setHeldOnPage(fromPage);
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
    const reservationKey = cloudReservation.handoff(environment);
    const team = cloudSwitchTeam.forSend();
    const request: CloudStart = {
      task: text,
      attachments,
      ...start,
      ...(environment ? { environment } : {}),
      ...(reservationKey ? { reservationKey } : {}),
      ...(team ? { team } : {}),
      // The empty chat this start replaces: the host closes this tab with it once the Cloud chat opens.
      ...(emptyLocalChat && sessionId ? { replacesChat: sessionId } : {}),
    };
    // A page's send leaves the page: its draft comes back in the chat composer, compared there.
    const preserved = fromPage || heldStillShown === false ? undefined : composerHandle.current?.draft();
    const started = beginCloudSend(request, false, preserved, fromPage);
    // A composer's send leaves the composer open and empty, as a local send does: the prompt shows
    // as the message (CloudStartView) and comes back if the start fails (`cloudStartHeld`).
    return Boolean(started) && !fromPage;
  };
  /// The person's click on a Cloud start's question (CloudStartAsk): the host takes it only from this
  /// pane and only with the click's own gesture; false lets the card's buttons take another click.
  const answerCloudStart = (id: string, button: string): Promise<boolean> =>
    cloudStart?.state === "starting"
      ? callNative("cloud.answerStart", { key: cloudStart.key, id, answer: button }).then(
          () => true,
          () => false,
        )
      : Promise.resolve(false);
  /// Retry on a failed Cloud start: the composer still holds its prompt, and sending it again keys the same
  /// start (cloudRun.ts `cloudStartKeys`), so the host reaches the machine the first try made.
  /// A Retry keeps the start's own folder: a start the too-big card sent without a folder retries without one, never
  /// from the composer's folder the preflight refused (Codex review F2 on #40957).
  const retryCloudStart = () => {
    if (cloudRetryFolder.current) cloudFolderOnce.current = cloudRetryFolder.current;
    sendStartPrompt();
  };
  /// The folder the next Cloud send names instead of the composer's (a too-big folder's card: a repository inside
  /// it, another folder, or none), taken once by that send.
  const cloudFolderOnce = useRef<{ cwd: string } | { home: true } | undefined>(undefined);
  /// The too-big card's way on: the same prompt, sent again in `folder` (a new start: another folder is another key).
  const sendCloudIn = (folder: { cwd: string } | { home: true }) => {
    cloudFolderOnce.current = folder;
    sendStartPrompt();
  };
  /// "This team has no Cloud plan": switch to the person's own team and send the same prompt again.
  const switchTeamAndRetry = (team: { id: string }) => {
    // The next Cloud send takes it (a send the composer holds for its files goes a moment later);
    // leaving Cloud or this chat drops it.
    cloudSwitchTeam.pick(team.id);
    retryCloudStart();
  };
  // The held send runs the render's latest `sendToCloud` (its offerable and checked), set after commit, not during render.
  useLayoutEffect(() => {
    sendToCloudLatest.current = sendToCloud;
    cloudPlanReady.set(() => {
      // The page's own hold (no plan at Send): that send goes now, the prompt taken from the composer as a Send that
      // went at once would, unless the person changed it meanwhile.
      const held = cloudPlanHeld.current;
      if (held) {
        sendHeldForPlan(held);
        return;
      }
      // The platform's refusal (no plan, or a machine larger than the plan includes): the same start again, once.
      if (
        cloudStart?.state === "failed" &&
        (cloudStart.code === "cloud_plan_required" || cloudStart.code === "cloud_size_locked")
      )
        retryCloudStart();
    });
  });
  // The held send goes once Cloud is offered here; leaving Cloud, a chat opening here or another
  // New Tab drops it.
  // The check answered that a chat is starting in this tab: the held send can't go, so its notice
  // becomes that refusal, with New Cloud chat.
  // `sandbox` is read when the effect runs, as the tab's state is then; its render-time fields are the deps.
  const checkAnswered = useEffectEvent(() => {
    if (!cloudWaitsForCheck) return;
    if (sandbox.mode !== "cloud" || (sessionId && !emptyLocalChat)) {
      cloudAfterCheck.drop();
      setCloudHeld(undefined);
    } else if (cloudOffered) {
      cloudAfterCheck.offered();
    } else if (sandbox.unread && cloudHeldOnPage.current) {
      cloudAfterCheck.drop();
      setCloudHeld(undefined);
    } else if (sandbox.checked && !cloudOfferable) {
      const held = cloudAfterCheck.take();
      setCloudHeld({
        refusal: translate("cloudStart.chatStartingHere"),
        prompt: held?.prompt ?? "",
        ...(held?.cwd ? { cwd: held.cwd } : {}),
      });
    }
  });
  useEffect(() => {
    checkAnswered();
  }, [
    cloudAfterCheck,
    cloudWaitsForCheck,
    cloudOffered,
    cloudOfferable,
    emptyLocalChat,
    sandboxChecked,
    sandboxUnread,
    sandboxMode,
    sessionId,
  ]);
  // Another New Tab, or leaving Cloud, ends what the held send said.
  useEffect(() => {
    cloudAfterCheck.drop();
    setCloudHeld(undefined);
  }, [cloudAfterCheck, newTabGeneration]);
  const heldLeftCloud = useEffectEvent(() => {
    if (sandbox.mode !== "cloud") setCloudHeld((held) => (held === "checking" ? held : undefined));
  });
  useEffect(() => {
    heldLeftCloud();
  }, [sandboxMode]);
  // Another chat shows here: the pane's own resets, then the Cloud send's, then the pane's again, as one effect.
  // The retry is made once (useState); the cancel reads only refs.
  const viewChanged = useEffectEvent(() => {
    viewReset.before();
    cloudSwitchTeam.reset();
    cloudPlanHeld.current = undefined;
    cloudPlanStore.reset();
    // Another chat shows here: a Cloud start's card belongs to the new chat it was sent from.
    cancelCloudSignIn();
    cloudSignInRetry.reset();
    setCloudStart(undefined);
    cloudSignInSend.set(() => undefined);
    cloudPageDraft.current = undefined;
    cloudStartHeld.current = undefined;
    cloudTypedDuringStart.current = undefined;
    newTabCloudSent.current = false;
    viewReset.after();
  });
  useEffect(() => {
    viewChanged();
  }, [sessionId, newTabGeneration, cloudReservation]);
  /// The person picked another place to run after a Cloud start failed: its card goes.
  const leftCloud = useEffectEvent(() => {
    if (sandbox.mode !== "cloud") {
      cloudReservation.abandon();
      cloudSwitchTeam.reset();
      cloudPlanHeld.current = undefined;
      cloudPlanStore.reset();
      cancelCloudSignIn();
      cloudSignInRetry.reset();
      setCloudStart((current) => (current?.state === "failed" ? undefined : current));
      cloudSignInSend.set(() => undefined);
    }
  });
  useEffect(() => {
    leftCloud();
  }, [sandboxMode, cloudReservation]);
  /// Run on This Mac from the cap card (runHereSend): the kept prompt sends once the mode is this Mac's.
  const runHereNow = useEffectEvent(() => {
    if (!runHereSend.current || sandbox.mode !== "persistent") return;
    runHereSend.current = false;
    sendStartPrompt();
  });
  useEffect(() => {
    runHereNow();
  }, [sandboxMode]);
  return {
    cloudStartPending,
    cloudPlanStore,
    cloudStartsEnded,
    cloudStart,
    setCloudStart,
    cloudSignInRetry,
    lastCloudAttempt,
    cloudStarting,
    cloudSendHeld,
    cloudStartingNow,
    cloudLeftPage,
    setCloudLeftPage,
    newTabCloudSent,
    cloudPageDraft,
    runCloudHere,
    cloudRetryFolder,
    dismissCloudFailure,
    setUpCloud,
    modelConnect,
    dismissCloudSetUp,
    cloudHeld,
    setCloudHeld,
    cloudWaitsForCheck,
    cloudPageHeld,
    sendToCloud,
    answerCloudStart,
    retryCloudStart,
    cloudFolderOnce,
    sendCloudIn,
    switchTeamAndRetry,
  };
}
