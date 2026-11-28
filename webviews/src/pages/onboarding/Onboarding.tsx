// The onboarding tool window's page (cmux-page://cmux.onboarding/): one page that draws whichever
// step the host says. The window is native (its placement, the one glass backdrop, the close
// button); this page paints no background of its own. Agents and Import share one scaffold: the
// title 52 from the top, its sentence 8 below, the body 28 below that, and a footer 28 from the
// bottom with Back (over the import explainers), Skip and the filled primary. Computer Use has its
// own layout. Return presses the primary (not on a repeat, nor when a text field, a focused button
// or an open popup owns it); Escape skips. While the webview is offline, one line under the title
// says so (sign-ins and downloads work once it is back); it goes by itself when the network returns.
import { useCallback, useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { DialogButton } from "../../ui/DialogButton";
import { StableLabel } from "../../ui/StableLabel";
import { useConnectionQuiet } from "../../ui/lasting";
import type { Strings } from "../shared/i18n";
import { AgentsStep, DEFAULT_AGENTS_LOOK, type AgentsLook } from "./AgentsStep";
import type { ProviderReadinessProps } from "../shared/signIn/ProviderReadiness";
import { ComputerUseStep } from "./ComputerUseStep";
import { ImportSources, ImportStep } from "./ImportStep";
import { DEFAULT_MAKE_IT_YOURS_LOOK, MakeItYoursStep, type MakeItYoursLook } from "./MakeItYoursStep";
import { OPS, type OnboardingFooter, type OnboardingState, type OnboardingStep } from "./ops";
import { OnboardingContext, useOnboarding, useOnline } from "./parts";
import { useOnboardingReadiness } from "./signInReadiness";
import type { OnboardingStore } from "./store";
import {
  EMPTY_HISTORY,
  MAKE_IT_YOURS_SCREENS,
  UNDOABLE_OPS,
  restoreWrites,
  walkValues,
  type MakeItYoursScreen,
  type WalkHistory,
  type WalkValues,
} from "./walk";
import { keyIntent, primaryLabel, primaryLabels, skipLabel, skipLabels, windowTitle } from "./text";

/** The Make cmux Yours walk's own screens: Back and the primary move between them before the host's. */
interface WalkNav {
  screen: number;
  go: (screen: number) => void;
  /** Undo and Redo over the walk's clicks (cmux#56827): every pick on any screen, one step each. */
  canUndo: boolean;
  canRedo: boolean;
  step: (direction: "undo" | "redo") => void;
}

/** The walk's Undo / Redo pair, leading the footer on every screen. Command-Z and Shift-Command-Z are
 * the page's key handler (a DialogButton's Command key does not tell Shift apart). */
function UndoRedo({ walk }: { walk: WalkNav }) {
  const { strings } = useOnboarding();
  return (
    <div className="onb-walk-undo">
      <DialogButton
        dialogKey={null}
        className="ui-button ui-btn"
        data-variant="subtle"
        data-size="md"
        aria-keyshortcuts="Meta+Z"
        disabled={!walk.canUndo}
        onClick={() => walk.step("undo")}
      >
        {strings.t("onboarding.button.undo")}
      </DialogButton>
      <DialogButton
        dialogKey={null}
        className="ui-button ui-btn"
        data-variant="subtle"
        data-size="md"
        aria-keyshortcuts="Meta+Shift+Z"
        disabled={!walk.canRedo}
        onClick={() => walk.step("redo")}
      >
        {strings.t("onboarding.button.redo")}
      </DialogButton>
    </div>
  );
}

function Footer({
  footer,
  step,
  leading,
  walk,
}: {
  footer: OnboardingFooter;
  step: OnboardingStep;
  leading?: ReactNode;
  walk?: WalkNav;
}) {
  const { strings, store } = useOnboarding();
  const inWalk = walk != null && walk.screen > 0;
  const walkNext = walk != null && walk.screen < MAKE_IT_YOURS_SCREENS.length - 1;
  const back = strings.t("onboarding.button.back");
  return (
    <footer className="onb-footer">
      {walk != null && <UndoRedo walk={walk} />}
      {leading}
      <div className="onb-footer-buttons">
        {/* The row is trailing-aligned: Back coming and going moves nothing else. */}
        {(footer.showsBack || inWalk) && (
          <DialogButton
            dialogKey={null}
            className="ui-button ui-btn"
            data-variant="subtle"
            data-size="md"
            disabled={!inWalk && !footer.backEnabled}
            onClick={() => (inWalk ? walk.go(walk.screen - 1) : store.call(OPS.back))}
          >
            {back}
          </DialogButton>
        )}
        {/* The intro walk's way out to a chat from any screen before the last (cmux#56827): it keeps
            every pick so far and ends the step as Continue on the last screen does; Skip still puts
            them back. */}
        {walkNext && (
          <DialogButton
            dialogKey={null}
            className="ui-button ui-btn"
            data-variant="subtle"
            data-size="md"
            data-walk-exit=""
            onClick={() => store.call(OPS.next)}
          >
            {strings.t("onboarding.button.startChatting")}
          </DialogButton>
        )}
        <DialogButton
          dialogKey="escape"
          className="ui-button ui-btn"
          data-variant="subtle"
          data-size="md"
          onClick={() => store.call(OPS.skip)}
        >
          <StableLabel label={skipLabel(strings, footer.skip)} alternatives={skipLabels(strings, step)} />
        </DialogButton>
        <DialogButton
          dialogKey="return"
          className="ui-button ui-btn"
          data-variant="solid"
          data-size="md"
          data-primary={footer.primary}
          disabled={!footer.primaryEnabled}
          onClick={() => (walkNext ? walk.go(walk.screen + 1) : store.call(OPS.next))}
        >
          <StableLabel label={primaryLabel(strings, footer.primary)} alternatives={primaryLabels(strings, step)} />
        </DialogButton>
      </div>
    </footer>
  );
}

const WALK_TEXT: Record<MakeItYoursScreen, { title: string; body: string }> = {
  look: {
    title: "onboarding.makeItYours.title",
    body: "onboarding.makeItYours.look.body",
  },
  work: {
    title: "onboarding.makeItYours.work.label",
    body: "onboarding.makeItYours.work.body",
  },
  trust: {
    title: "onboarding.makeItYours.trust.title",
    body: "onboarding.makeItYours.trust.body",
  },
  tune: {
    title: "onboarding.makeItYours.tune.title",
    body: "onboarding.makeItYours.tune.body",
  },
};

function Scaffold({
  state,
  agentsLook,
  makeItYoursLook,
  walk,
  opened,
  readiness,
  online,
}: {
  state: OnboardingState;
  agentsLook: AgentsLook;
  makeItYoursLook: MakeItYoursLook;
  walk: WalkNav;
  opened: WalkValues | null;
  readiness?: ProviderReadinessProps;
  online: boolean;
}) {
  const { strings } = useOnboarding();
  const agents = state.step === "agents";
  const make = state.step === "makeItYours";
  // experiments.introWalk off (the default): today's one screen, its title and sentence, no walk.
  const walkOn = make && state.makeItYours?.introWalk === true;
  const screen = MAKE_IT_YOURS_SCREENS[walk.screen] ?? "look";
  const makeText = walkOn
    ? WALK_TEXT[screen]
    : {
        title: "onboarding.makeItYours.title",
        body: "onboarding.makeItYours.body",
      };
  const sources = !agents && !make && state.importer != null ? <ImportSources importer={state.importer} /> : null;
  // A network blip says nothing; only an outage past the shared quiet bound shows the line.
  const offlineShown = useConnectionQuiet(!online);
  return (
    <div className="onb-scaffold" data-step={state.step}>
      <header className="onb-header">
        <h1 className="onb-title">
          {agents
            ? strings.t("onboarding.agents.heading")
            : make
              ? strings.t(makeText.title)
              : strings.t("onboarding.import.title2")}
        </h1>
        {agents && <p className="onb-sentence">{strings.t("onboarding.agents.body")}</p>}
        {make && <p className="onb-sentence">{strings.t(makeText.body)}</p>}
        {offlineShown && (
          <output className="onb-offline" aria-live="polite">
            {strings.t("onboarding.offline")}
          </output>
        )}
      </header>
      <div className="onb-body">
        {agents ? (
          <AgentsStep agents={state.agents} look={agentsLook} readiness={readiness} />
        ) : make ? (
          <MakeItYoursStep
            choices={state.makeItYours}
            look={makeItYoursLook}
            screen={walkOn ? screen : "all"}
            opened={opened}
          />
        ) : state.importer != null ? (
          <ImportStep importer={state.importer} progress={state.footer.progress} />
        ) : null}
      </div>
      <Footer footer={state.footer} step={state.step} leading={sources} walk={walkOn ? walk : undefined} />
    </div>
  );
}

export function OnboardingPage({
  store,
  strings,
  agentsLook = DEFAULT_AGENTS_LOOK,
  makeItYoursLook = DEFAULT_MAKE_IT_YOURS_LOOK,
  makeItYoursScreen = "look",
  online: onlineOverride,
}: {
  store: OnboardingStore;
  strings: Strings;
  agentsLook?: AgentsLook;
  makeItYoursLook?: MakeItYoursLook;
  /** The walk's screen the step opens on with experiments.introWalk on (tests and the gallery; the app opens on the look). */
  makeItYoursScreen?: MakeItYoursScreen;
  /** The network state to draw instead of the webview's own (the gallery and tests). */
  online?: boolean;
}) {
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  // The walk's screen, local to the page: the host has one Make cmux Yours step. Read by the key handler.
  const [screen, setScreen] = useState(() => Math.max(0, MAKE_IT_YOURS_SCREENS.indexOf(makeItYoursScreen)));
  const screenRef = useRef(screen);
  screenRef.current = screen;
  // The settings when the step first showed, for House and the rows' "as before".
  const opened = useRef<WalkValues | null>(null);
  if (state?.step === "makeItYours" && state.makeItYours && opened.current == null)
    opened.current = walkValues(state.makeItYours);
  const step = state?.step;
  // The walk's Undo / Redo history (cmux#56827): the settings before each click on any of its screens.
  const [history, setHistory] = useState<WalkHistory>(EMPTY_HISTORY);
  const historyRef = useRef(history);
  historyRef.current = history;
  // Set while Undo or Redo sends its own writes, so they are not recorded as clicks.
  const replaying = useRef(false);
  useEffect(() => {
    store.onGesture = (op, before) => {
      if (replaying.current || !UNDOABLE_OPS.has(op)) return;
      const choices = before?.step === "makeItYours" ? before.makeItYours : null;
      if (choices?.introWalk !== true) return;
      const snapshot = walkValues(choices);
      setHistory(({ past }) => ({ past: [...past, snapshot], future: [] }));
    };
    return () => {
      store.onGesture = null;
    };
  }, [store]);
  const stepHistory = useCallback(
    (direction: "undo" | "redo") => {
      const choices = store.getSnapshot()?.makeItYours;
      const { past, future } = historyRef.current;
      const target = direction === "undo" ? past.at(-1) : future[0];
      if (choices == null || target == null) return;
      const now = walkValues(choices);
      const next =
        direction === "undo"
          ? { past: past.slice(0, -1), future: [now, ...future] }
          : { past: [...past, now], future: future.slice(1) };
      historyRef.current = next;
      setHistory(next);
      const { workStyle, writes } = restoreWrites(target, now);
      replaying.current = true;
      try {
        if (workStyle != null) store.call(OPS.workStyle, { value: workStyle });
        if (writes.length > 0) store.call(OPS.walk, { writes });
      } finally {
        replaying.current = false;
      }
    },
    [store],
  );
  const stepHistoryRef = useRef(stepHistory);
  stepHistoryRef.current = stepHistory;
  useEffect(() => {
    // Leaving the step (Back to the step before) starts the walk over at its first screen when it comes back.
    if (step !== "makeItYours") {
      setScreen(0);
      setHistory(EMPTY_HISTORY);
    }
  }, [step]);
  const browserOnline = useOnline();
  const online = onlineOverride ?? browserOnline;
  // The agents step's in-place sign-in, from the host's `signInReadiness` (none: as before).
  const readiness = useOnboardingReadiness(store, state);
  useEffect(() => {
    document.title = windowTitle(strings, state);
  }, [strings, state]);
  useEffect(() => {
    const press = (event: KeyboardEvent) => {
      // A held Return repeats: only a fresh press acts. Its repeats would also activate the focused
      // button natively, and that button may turn into the next step's (Import, then Begin Importing).
      if (event.key === "Enter" && event.repeat) {
        event.preventDefault();
        return;
      }
      const current = store.getSnapshot();
      if (!current) return;
      // Command-Z steps the walk back, Shift-Command-Z forward (not in a text field, which keeps its own).
      if (
        event.metaKey &&
        !event.ctrlKey &&
        !event.altKey &&
        event.key.toLowerCase() === "z" &&
        current.step === "makeItYours" &&
        current.makeItYours?.introWalk === true &&
        !(event.target instanceof HTMLElement && event.target.closest("input[type=text], textarea, [contenteditable]"))
      ) {
        event.preventDefault();
        stepHistoryRef.current(event.shiftKey ? "redo" : "undo");
        return;
      }
      // Return is the window's one primary action; on Computer Use the model picks it (the next
      // row's Allow, Restart for a helper that did not answer, or Done).
      const intent = keyIntent(event, current.footer);
      if (!intent) return;
      event.preventDefault();
      // Return walks the Make cmux Yours screens before Continue leaves the step.
      if (
        intent !== "skip" &&
        current.step === "makeItYours" &&
        current.makeItYours?.introWalk === true &&
        screenRef.current < MAKE_IT_YOURS_SCREENS.length - 1
      ) {
        setScreen(screenRef.current + 1);
        return;
      }
      store.call(intent === "skip" ? OPS.skip : OPS.next);
    };
    window.addEventListener("keydown", press);
    return () => window.removeEventListener("keydown", press);
  }, [store]);
  return (
    <OnboardingContext.Provider value={{ strings, store }}>
      <div className="onboarding" data-step={state?.step ?? "loading"}>
        {state == null ? null : state.step === "computerUse" ? (
          state.computerUse != null ? (
            <ComputerUseStep computerUse={state.computerUse} />
          ) : null
        ) : (
          <Scaffold
            state={state}
            agentsLook={agentsLook}
            makeItYoursLook={makeItYoursLook}
            walk={{
              screen,
              go: setScreen,
              canUndo: history.past.length > 0,
              canRedo: history.future.length > 0,
              step: stepHistory,
            }}
            opened={opened.current}
            readiness={readiness}
            online={online}
          />
        )}
      </div>
    </OnboardingContext.Provider>
  );
}
