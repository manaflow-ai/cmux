// The onboarding tool window's page (cmux-page://cmux.onboarding/): one page that draws whichever
// step the host says. The window is native (its placement, the one glass backdrop, the close
// button); this page paints no background of its own. Agents and Import share one scaffold: the
// title 52 from the top, its sentence 8 below, the body 28 below that, and a footer 28 from the
// bottom with Back (over the import explainers), Skip and the filled primary. Computer Use has its
// own layout. Return presses the primary (not on a repeat, nor when a text field, a focused button
// or an open popup owns it); Escape skips.
import { useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { DialogButton } from "../../ui/DialogButton";
import { StableLabel } from "../../ui/StableLabel";
import type { Strings } from "../shared/i18n";
import { AgentsStep, DEFAULT_AGENTS_LOOK, type AgentsLook } from "./AgentsStep";
import type { ProviderReadinessProps } from "../shared/signIn/ProviderReadiness";
import { ComputerUseStep } from "./ComputerUseStep";
import { ImportSources, ImportStep } from "./ImportStep";
import { DEFAULT_MAKE_IT_YOURS_LOOK, MakeItYoursStep, type MakeItYoursLook } from "./MakeItYoursStep";
import { OPS, type OnboardingFooter, type OnboardingState, type OnboardingStep } from "./ops";
import { OnboardingContext, useOnboarding } from "./parts";
import { useOnboardingReadiness } from "./signInReadiness";
import type { OnboardingStore } from "./store";
import { MAKE_IT_YOURS_SCREENS, walkValues, type MakeItYoursScreen, type WalkValues } from "./walk";
import { keyIntent, primaryLabel, primaryLabels, skipLabel, skipLabels, windowTitle } from "./text";

/** The Make cmux Yours walk's own screens: Back and the primary move between them before the host's. */
interface WalkNav {
  screen: number;
  go: (screen: number) => void;
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
}: {
  state: OnboardingState;
  agentsLook: AgentsLook;
  makeItYoursLook: MakeItYoursLook;
  walk: WalkNav;
  opened: WalkValues | null;
  readiness?: ProviderReadinessProps;
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
}: {
  store: OnboardingStore;
  strings: Strings;
  agentsLook?: AgentsLook;
  makeItYoursLook?: MakeItYoursLook;
  /** The walk's screen the step opens on with experiments.introWalk on (tests and the gallery; the app opens on the look). */
  makeItYoursScreen?: MakeItYoursScreen;
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
  useEffect(() => {
    // Leaving the step (Back to the step before) starts the walk over at its first screen when it comes back.
    if (step !== "makeItYours") setScreen(0);
  }, [step]);
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
            walk={{ screen, go: setScreen }}
            opened={opened.current}
            readiness={readiness}
          />
        )}
      </div>
    </OnboardingContext.Provider>
  );
}
