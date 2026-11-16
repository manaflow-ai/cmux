// A malformed-request refusal names what the app blocked, by the method the host's refusal names
// (`data.method`, AcpmuxPaneMethods `refusal`). Every chat typed on New Tab failed with "Couldn't
// start Codex: Something went wrong, so that didn't go through." and nothing said that the app had
// refused the chat's open (#42460). Still plain words: no request, pane, intent or Try again.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { startFailureView } from "../src/agent-session/acpmux/startFailure";
import { errorMessage } from "../src/agent-session/acpmux/transportErrors";

/// The error direct.ts builds from the host's refusal frame.
function refusal(method?: string): Error {
  return Object.assign(new Error("Refused by the cmux host"), {
    code: "transport.intent_invalid",
    ...(method ? { method } : {}),
  });
}

function quietly<T>(run: () => T): T {
  const original = console.error;
  console.error = () => {};
  try {
    return run();
  } finally {
    console.error = original;
  }
}

test("a refused open, start, send or setting says which", () => {
  const cases: [string, Parameters<typeof translate>[0]][] = [
    ["_acpmux/attach", "transport.intentInvalidOpen"],
    ["session/new", "transport.intentInvalidStart"],
    ["session/prompt", "transport.intentInvalidSend"],
    ["session/set_config_option", "transport.intentInvalidSetting"],
  ];
  for (const [method, key] of cases) {
    const text = quietly(() => errorMessage(refusal(method)));
    expect(text).toBe(translate(key));
    expect(text).not.toBe(translate("transport.intentInvalid"));
    for (const jargon of [/\brequest\b/i, /\bpane\b/i, /intent/i, /try again/i, /went wrong/i])
      expect(text).not.toMatch(jargon);
  }
});

test("a refusal with no known method keeps the generic line", () => {
  expect(quietly(() => errorMessage(refusal()))).toBe(translate("transport.intentInvalid"));
  expect(quietly(() => errorMessage(refusal("_acpmux/typing")))).toBe(translate("transport.intentInvalid"));
});

test("the start card for a refused open names it, not 'Something went wrong'", () => {
  const t = (key: Parameters<typeof translate>[0], values?: Record<string, string | number>) => translate(key, values);
  const error = quietly(() => errorMessage(refusal("_acpmux/attach")));
  const view = startFailureView(t, { harness: "codex", name: "Codex", error, code: "transport.intent_invalid" });
  expect(view.sentence).toBe(translate("switch.failed", { agent: "Codex", reason: translate("transport.intentInvalidOpen") }));
  expect(view.sentence).not.toContain(translate("transport.intentInvalid"));
});
