// `debug.agent_pane toast`: a capture raises a pane toast by its text, as a refusal or a click's
// feedback does, so the toasts' stacking, count and lift can be driven with no failed turn.
import { expect, test } from "bun:test";
import { createAcpmuxDebug } from "./debug";

test("the debug toast shows its text through the pane's toasts", () => {
  const shown: string[] = [];
  const debug = createAcpmuxDebug({
    replaceRows: () => undefined,
    rowCount: () => 0,
    toast: (text) => shown.push(text),
  });
  expect(debug.toast("Nothing to continue")).toEqual({ shown: true, text: "Nothing to continue" });
  debug.toast("Nothing to continue");
  expect(shown).toEqual(["Nothing to continue", "Nothing to continue"]);
});

test("with no pane toasts the debug toast says it showed nothing", () => {
  const debug = createAcpmuxDebug({ replaceRows: () => undefined, rowCount: () => 0 });
  expect(debug.toast("x")).toEqual({ shown: false, text: "x" });
});
