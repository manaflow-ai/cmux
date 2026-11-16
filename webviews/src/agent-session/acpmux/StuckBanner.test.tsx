import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { StuckBanner } from "./StuckBanner";
import { prefillStuckNudge } from "./stuckNudge";
import type { Translate } from "./i18n";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("Nudge pre-fills the diagnosis, keeps the draft editable, and never sends", async () => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "IS_REACT_ACT_ENVIRONMENT",
    "__cmuxPaneStrings",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    __cmuxPaneStrings: {
      en: {
        "stuck.title": "Agent may be stuck",
        "stuck.nudge": "Nudge with hint",
        "stuck.nudgePrompt": "The agent may be stuck: {diagnosis}. Please try a different approach.",
      },
    },
  });
  const container = dom.window.document.getElementById("root")!;
  const draft = dom.window.document.createElement("textarea");
  draft.value = "Check the auth tests too.";
  dom.window.document.body.appendChild(draft);
  let sends = 0;
  const composer = {
    prefill(prefix: string) {
      if (!draft.value.startsWith(prefix.trimEnd())) draft.value = prefix + draft.value;
      draft.focus();
    },
    send() {
      sends += 1;
    },
  };
  const diagnosis = "Ran cargo test 4 times; the same error in auth.rs:88 each time";
  const t: Translate = (_key, values) =>
    `The agent may be stuck: ${values?.diagnosis}. Please try a different approach.`;
  root = createRoot(container);
  await act(async () =>
    root!.render(<StuckBanner diagnosis={diagnosis} onNudge={() => prefillStuckNudge(composer, diagnosis, t)} />),
  );
  const button = container.querySelector<HTMLButtonElement>(".acpmux-stuck-nudge")!;
  expect(container.textContent).toContain(diagnosis);
  expect(button.textContent).toBe("Nudge with hint");
  await act(async () => button.click());
  expect(draft.value).toBe(
    `The agent may be stuck: ${diagnosis}. Please try a different approach.\n\nCheck the auth tests too.`,
  );
  expect(dom.window.document.activeElement).toBe(draft);
  draft.value += " Use the smaller fixture.";
  await act(async () => button.click());
  expect(draft.value).toContain("Check the auth tests too. Use the smaller fixture.");
  expect(draft.value.match(/The agent may be stuck:/g)).toHaveLength(1);
  expect(sends).toBe(0);
});
