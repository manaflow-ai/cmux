import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PendingSteer } from "./PendingSteer";
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

async function render(sendResult: boolean) {
  const container = installDom();
  function Harness() {
    const [row, setRow] = useState<AcpmuxRow>(waiting);
    return (
      <TurnActionsContext.Provider value={{}}>
        <PendingSteer
          row={row}
          send={async () => {
            if (sendResult) setRow({ ...row, steer: undefined, steerPromptId: undefined });
            return sendResult;
          }}
        />
      </TurnActionsContext.Provider>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Harness />);
  });
  return container;
}

test("Send now disappears when delivery succeeds", async () => {
  const succeeded = await render(true);
  const successButton = succeeded.querySelector<HTMLButtonElement>(".cv-user__send-now")!;
  await act(async () => successButton.click());
  expect(succeeded.querySelector(".cv-user__send-now")).toBeNull();
});

test("Send now remains available when delivery fails", async () => {
  const failed = await render(false);
  const failureButton = failed.querySelector<HTMLButtonElement>(".cv-user__send-now")!;
  await act(async () => failureButton.click());
  expect(failed.querySelector(".cv-user__send-now")).not.toBeNull();
});
