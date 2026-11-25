// The chat front's first interaction at launch: the frame where the composer first drew a key the person typed.
// Once per document, and only while a launch harness reads the marks (the host's `__snapshot/chat.js` sets
// `__cmuxLaunchMeasured`, as for launchSettle.ts): the page reports `pane.inputEchoed {echoedEpochMs}` and the host
// turns it into the launch mark `agent_pane.input_echoed` on the process's clock (AgentPaneLaunchTimings
// `inputEchoed`), the stage `first_interaction` of a chat front (scripts/ci/launch_tti_check.py). A person's launch
// runs nothing here.
//
// A key the chat's saved copy swallowed (chatSnapshot/live.ts) never reaches this watch; a change of the prompt
// with no typed key before it (a restored draft) is no echo.

type Report = (method: string, params: Record<string, unknown>) => Promise<unknown>;

let report: Report | undefined;
let keyed = false;
let reported = false;

/// Starts this document's watch for the person's first key (call it at the chat's first paint); later calls, and
/// every call with no launch harness reading, do nothing. `send` posts the report once.
export function watchLaunchInputEcho(send: Report, doc: Document = document): void {
  const view = doc.defaultView;
  const measured = (view as (Window & { __cmuxLaunchMeasured?: boolean }) | null)?.__cmuxLaunchMeasured === true;
  if (report || reported || !view || !measured) return;
  report = send;
  const key = () => {
    keyed = true;
    view.removeEventListener("keydown", key, true);
  };
  view.addEventListener("keydown", key, { capture: true, passive: true });
}

/// The composer's prompt changed (ComposerBox `onChange`): the first change after a typed key reports the frame
/// that draws it, once.
export function composerChanged(view: Window = window): void {
  if (reported || !report || !keyed) return;
  reported = true;
  const send = report;
  // After the frame that draws the change (the paint report's own rAF + task, App.tsx `pane.painted`).
  view.requestAnimationFrame(() =>
    view.setTimeout(() => void send("pane.inputEchoed", { echoedEpochMs: Date.now() }).catch(() => undefined), 0),
  );
}

/// Tests only: a fresh document's state.
export function resetLaunchInputEchoForTest(): void {
  report = undefined;
  keyed = false;
  reported = false;
}
