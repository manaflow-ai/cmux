// The onboarding tool window's page (cmux-page://cmux.onboarding/): one page that draws whichever
// step the host says. The window is native (its placement, the one glass backdrop, the close
// button); this page paints no background of its own. Agents and Import share one scaffold: the
// title 52 from the top, its sentence 8 below, the body 28 below that, and a footer 28 from the
// bottom with Back (over the import explainers), Skip and the filled primary. Computer Use has its
// own layout. Return presses the primary (not on a repeat, nor when a text field, a focused button
// or an open popup owns it); Escape skips.
import { useEffect, useSyncExternalStore, type ReactNode } from "react";
import { DialogButton } from "../../ui/DialogButton";
import { StableLabel } from "../../ui/StableLabel";
import type { Strings } from "../shared/i18n";
import { AgentsStep, DEFAULT_AGENTS_LOOK, type AgentsLook } from "./AgentsStep";
import { ComputerUseStep } from "./ComputerUseStep";
import { ImportSources, ImportStep } from "./ImportStep";
import { OPS, type OnboardingFooter, type OnboardingState, type OnboardingStep } from "./ops";
import { OnboardingContext, useOnboarding } from "./parts";
import type { OnboardingStore } from "./store";
import { keyIntent, primaryLabel, primaryLabels, skipLabel, skipLabels, windowTitle } from "./text";

function Footer({ footer, step, leading }: { footer: OnboardingFooter; step: OnboardingStep; leading?: ReactNode }) {
  const { strings, store } = useOnboarding();
  const back = strings.t("onboarding.button.back");
  return (
    <footer className="onb-footer">
      {leading}
      <div className="onb-footer-buttons">
        {/* The row is trailing-aligned: Back coming and going moves nothing else. */}
        {footer.showsBack && (
          <DialogButton
            dialogKey={null}
            className="ui-button ui-btn"
            data-variant="subtle"
            data-size="md"
            disabled={!footer.backEnabled}
            onClick={() => store.call(OPS.back)}
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
          onClick={() => store.call(OPS.next)}
        >
          <StableLabel label={primaryLabel(strings, footer.primary)} alternatives={primaryLabels(strings, step)} />
        </DialogButton>
      </div>
    </footer>
  );
}

function Scaffold({ state, agentsLook }: { state: OnboardingState; agentsLook: AgentsLook }) {
  const { strings } = useOnboarding();
  const agents = state.step === "agents";
  const sources = !agents && state.importer != null ? <ImportSources importer={state.importer} /> : null;
  return (
    <div className="onb-scaffold" data-step={state.step}>
      <header className="onb-header">
        <h1 className="onb-title">
          {agents ? strings.t("onboarding.agents.heading") : strings.t("onboarding.import.title2")}
        </h1>
        {agents && <p className="onb-sentence">{strings.t("onboarding.agents.body")}</p>}
      </header>
      <div className="onb-body">
        {agents ? (
          <AgentsStep agents={state.agents} look={agentsLook} />
        ) : state.importer != null ? (
          <ImportStep importer={state.importer} progress={state.footer.progress} />
        ) : null}
      </div>
      <Footer footer={state.footer} step={state.step} leading={sources} />
    </div>
  );
}

export function OnboardingPage({
  store,
  strings,
  agentsLook = DEFAULT_AGENTS_LOOK,
}: {
  store: OnboardingStore;
  strings: Strings;
  agentsLook?: AgentsLook;
}) {
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
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
          <Scaffold state={state} agentsLook={agentsLook} />
        )}
      </div>
    </OnboardingContext.Provider>
  );
}
