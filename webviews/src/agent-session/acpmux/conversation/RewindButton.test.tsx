// Back to before this turn on a sent prompt (MessageActions.tsx RewindButton): shown only for a
// prompt whose Cloud checkpoint is ready, never read only, and its idle, pending, done and failed
// states, a failed one trying again on a second click.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { translate } from "../i18n";
import { TranscriptReadOnly } from "./readOnly";
import { TurnActionsContext, type TurnActions } from "./turnActions";
import { UserBubble } from "./UserBubble";
import { rewindSeconds } from "./MessageActions";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const row = (): AcpmuxRow => ({
  id: "user-4",
  version: 1,
  kind: "user",
  at: Date.now() - 10_000,
  text: "Now cover it with a test",
});

async function render(actions: TurnActions, readOnly = false): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <TranscriptReadOnly.Provider value={readOnly}>
        <TurnActionsContext.Provider value={actions}>
          <UserBubble row={row()} text="Now cover it with a test" />
        </TurnActionsContext.Provider>
      </TranscriptReadOnly.Provider>,
    );
  });
  return container;
}

/// A rewind whose answers the test settles by hand, one per call.
function manualRewind(ready: string[] = ["user-4"]) {
  const calls: { rowId: string; resolve(seconds: number): void; reject(): void }[] = [];
  const rewind: NonNullable<TurnActions["rewind"]> = {
    ready: new Set(ready),
    before: (rowId) =>
      new Promise((resolve, reject) =>
        calls.push({ rowId, resolve: (seconds) => resolve({ seconds }), reject: () => reject(new Error("refused")) }),
      ),
  };
  return { rewind, calls };
}

const button = (container: HTMLElement) => container.querySelector<HTMLButtonElement>(".cv-turn-rewind");

test("no rewind, a prompt without a ready checkpoint, or a read-only transcript draws no button", async () => {
  expect(button(await render({}))).toBeNull();
  expect(button(await render({ rewind: manualRewind(["user-1"]).rewind }))).toBeNull();
  expect(button(await render({ rewind: manualRewind().rewind }, true))).toBeNull();
});

test("a rewind goes idle, pending, then done with its time, and a done one does not run again", async () => {
  const { rewind, calls } = manualRewind();
  const container = await render({ rewind });
  const idle = button(container)!;
  expect(idle.dataset.rewindState).toBe("idle");
  expect(idle.getAttribute("aria-label")).toBe(translate("turn.rewind"));
  expect(idle.title).toBe(translate("turn.rewind"));

  await act(async () => idle.click());
  expect(calls.map((call) => call.rowId)).toEqual(["user-4"]);
  const pending = button(container)!;
  expect(pending.dataset.rewindState).toBe("pending");
  expect(pending.disabled).toBe(true);
  expect(pending.getAttribute("aria-busy")).toBe("true");
  expect(pending.getAttribute("aria-label")).toBe(translate("turn.rewinding"));
  expect(pending.querySelector(".cv-spinner, svg")).not.toBeNull();

  await act(async () => calls[0]!.resolve(9.43));
  const done = button(container)!;
  expect(done.dataset.rewindState).toBe("done");
  expect(done.getAttribute("aria-label")).toBe(translate("turn.rewound", { seconds: "9.4" }));
  expect(done.getAttribute("aria-label")).toContain("9.4 s");
  expect(done.getAttribute("aria-disabled")).toBe("true");

  await act(async () => done.click());
  expect(calls.length).toBe(1);
});

test("a failed rewind says so, and a second click tries again", async () => {
  const { rewind, calls } = manualRewind();
  const container = await render({ rewind });
  await act(async () => button(container)!.click());
  await act(async () => calls[0]!.reject());
  const failed = button(container)!;
  expect(failed.dataset.rewindState).toBe("failed");
  expect(failed.disabled).toBe(false);
  expect(failed.getAttribute("aria-label")).toBe(translate("turn.rewindFailed"));

  await act(async () => failed.click());
  expect(calls.length).toBe(2);
  expect(button(container)!.dataset.rewindState).toBe("pending");
  await act(async () => calls[1]!.resolve(10));
  expect(button(container)!.getAttribute("aria-label")).toBe(translate("turn.rewound", { seconds: "10.0" }));
});

test("the button follows Fork in the prompt's row", async () => {
  const { rewind } = manualRewind();
  const container = await render({ rewind, fork: () => {}, forkSeq: 6, promptTurns: new Map([["user-4", 6]]) });
  const labels = [...container.querySelectorAll(".cv-user__actions button")].map((node) =>
    node.getAttribute("aria-label"),
  );
  expect(labels.indexOf(translate("turn.rewind"))).toBe(labels.indexOf(translate("turn.fork")) + 1);
});

test("a rewind's seconds keep one decimal in the pane's language", () => {
  expect(rewindSeconds(9.43, "en")).toBe("9.4");
  expect(rewindSeconds(16, "en")).toBe("16.0");
  expect(rewindSeconds(9.43, "de")).toBe("9,4");
});
