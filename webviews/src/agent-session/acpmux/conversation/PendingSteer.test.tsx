import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PendingSteer, takesSteersBack } from "./PendingSteer";
import { TurnActionsContext } from "./turnActions";
import type { AcpmuxRow } from "../model";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

const waiting: AcpmuxRow = {
  id: "user-1",
  version: 1,
  at: 1,
  kind: "user",
  text: "Use the cache dir",
  steer: "waiting",
  steerPromptId: "p-1",
};

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
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

// acpmux answers send_now before the agent reads the steer: its row still says waiting then, as on
// Leo's row (2026-10-24: "after i clicked send now and it worked it should just disappear").
async function render(sendResult: boolean) {
  const container = installDom();
  const unsteer = async () => true;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <TurnActionsContext.Provider value={{ unsteer }}>
        <PendingSteer row={waiting} send={async () => sendResult} />
      </TurnActionsContext.Provider>,
    );
  });
  return container;
}

const settle = (ms: number) => act(() => new Promise<void>((resolve) => setTimeout(resolve, ms)));

test("Send now and the X fade out once Send now worked, while the steer still reads waiting", async () => {
  const container = await render(true);
  expect(container.querySelector(".cv-user__take-back")).not.toBeNull();
  const button = container.querySelector<HTMLButtonElement>(".cv-user__send-now")!;
  await act(async () => button.click());
  // At once it leaves: no second click, and it fades and folds its width (no line moves).
  const leaving = container.querySelector<HTMLElement>(".cv-user__pending--leaving");
  expect(leaving).not.toBeNull();
  expect(leaving!.getAttribute("aria-hidden")).toBe("true");
  expect(button.disabled).toBe(true);
  await settle(400);
  expect(container.querySelector(".cv-user__pending")).toBeNull();
});

test("Send now remains available when delivery fails", async () => {
  const failed = await render(false);
  const failureButton = failed.querySelector<HTMLButtonElement>(".cv-user__send-now")!;
  await act(async () => failureButton.click());
  await settle(400);
  expect(failed.querySelector(".cv-user__send-now")).not.toBeNull();
  expect(failed.querySelector(".cv-user__pending--leaving")).toBeNull();
});

// Leo, 2026-10-24: "where's the, like, X button? All I see is the send now". His Claude chats run
// a Claude Code profile under its own family name (claude-sr2): the X follows what the agent can do
// (acpmux steers only through its Claude Code adapter, which takes a steer back), not the name.
test("the X is offered wherever the agent steers, whatever its family is named", () => {
  expect(takesSteersBack({ harness: "claude-sr2", family: "claude-sr2", steering: true }, true)).toBe(true);
  expect(takesSteersBack({ harness: "claude", family: "claude", steering: true }, true)).toBe(true);
  expect(takesSteersBack({ harness: "codex", family: "codex", steering: false }, true)).toBe(false);
  expect(takesSteersBack({ harness: "claude", family: "claude", steering: true }, false)).toBe(false);
});
