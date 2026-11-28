// An open Share dialog reads its chat's shares again when the daemon says they changed (a request,
// a role change or a removal made elsewhere), and a closed one does not.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ShareDialogHost } from "./ShareControl";
import { shareChanged } from "./shareChanges";
import type { ShareCall } from "./shareState";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

test("an open Share dialog reads its chat's shares again on each change the daemon reports", async () => {
  const host = installDom();
  let reads = 0;
  const call: ShareCall = async (op) => {
    if (op === "state") reads += 1;
    return { shares: [] };
  };
  const draw = (open: boolean) =>
    root!.render(
      <ShareDialogHost sessionId="acp_1" chat="Chat" open={open} onOpenChange={() => {}} call={call} />,
    );
  root = createRoot(host);
  await act(async () => draw(true));
  await settle();
  expect(reads).toBe(1);

  await act(async () => shareChanged("acp_1"));
  await settle();
  expect(reads).toBe(2);

  // Another chat's change is not this dialog's.
  await act(async () => shareChanged("acp_2"));
  await settle();
  expect(reads).toBe(2);

  // Closed, it hears nothing.
  await act(async () => draw(false));
  await settle();
  await act(async () => shareChanged("acp_1"));
  await settle();
  expect(reads).toBe(2);
});
