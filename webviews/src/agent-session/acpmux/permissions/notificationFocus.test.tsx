// A click on an ask's notification opens the chat with its permission card holding the keyboard
// (`permissionFocus`, NotificationCenterService.open), so one key answers: one keystroke from the
// click to the answer, never the composer first.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { permissionFromMessage } from "../direct";
import { askPermissionFocus, FOCUS_REQUEST_MS, takePermissionFocus } from "./focusRequest";
import { PermissionCard } from "../PermissionCard";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "KeyboardEvent",
  "CustomEvent",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><textarea id=composer></textarea><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    CustomEvent: dom.window.CustomEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  takePermissionFocus();
  if (root) await act(async () => root!.unmount());
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

/// A pending Bash ask with Allow once, Always allow and Deny.
const ask = {
  sessionId: "s1",
  permissionId: "p1",
  request: {
    sessionId: "s1",
    toolCall: {
      toolCallId: "bash-1",
      status: "pending",
      title: "npm test",
      kind: "execute",
      rawInput: { command: "npm test" },
    },
    options: [
      { optionId: "once", name: "Allow once", kind: "allow_once" },
      { optionId: "always", name: "Always allow", kind: "allow_always" },
      { optionId: "no", name: "Deny", kind: "reject_once" },
    ],
  },
};

test("a notification click puts the waiting card's keys under the next key press", async () => {
  const container = installDom();
  const doc = dom!.window.document;
  const composer = doc.getElementById("composer") as HTMLTextAreaElement;
  const answers: string[] = [];
  const permission = permissionFromMessage(ask, "s1")!;
  root = createRoot(container);
  await act(async () => {
    root!.render(<PermissionCard permission={permission} harness="claude" onAnswer={(id) => answers.push(id)} />);
  });
  // The chat opens with the composer holding the keyboard: a 1 there would be typed, not answered.
  composer.focus();
  await act(async () => {
    dom!.window.dispatchEvent(new dom!.window.CustomEvent("cmux-acpmux-permissionFocus"));
  });
  const card = container.querySelector(".acpmux-permission-ask");
  expect(doc.activeElement).toBe(card);
  await act(async () => {
    doc.activeElement!.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "1", bubbles: true }));
  });
  expect(answers).toEqual(["once"]);
});

test("with no ask waiting the event takes nothing from the composer", async () => {
  const container = installDom();
  const doc = dom!.window.document;
  const composer = doc.getElementById("composer") as HTMLTextAreaElement;
  const permission = { ...permissionFromMessage(ask, "s1")!, pending: false };
  root = createRoot(container);
  await act(async () => {
    root!.render(<PermissionCard permission={permission} harness="claude" onAnswer={() => undefined} />);
  });
  composer.focus();
  await act(async () => {
    dom!.window.dispatchEvent(new dom!.window.CustomEvent("cmux-acpmux-permissionFocus"));
  });
  expect(doc.activeElement).toBe(composer);
});

test("a card that mounts just after the click still takes the keyboard", async () => {
  const container = installDom();
  const doc = dom!.window.document;
  const composer = doc.getElementById("composer") as HTMLTextAreaElement;
  const answers: string[] = [];
  composer.focus();
  // The click arrives while the chat opens, before its card is there.
  askPermissionFocus();
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <PermissionCard
        permission={permissionFromMessage(ask, "s1")!}
        harness="claude"
        onAnswer={(id) => answers.push(id)}
      />,
    );
  });
  expect(doc.activeElement).toBe(container.querySelector(".acpmux-permission-ask"));
  await act(async () => {
    doc.activeElement!.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "1", bubbles: true }));
  });
  expect(answers).toEqual(["once"]);
});

test("a click long before the card mounts takes nothing from the composer", async () => {
  const container = installDom();
  const doc = dom!.window.document;
  const composer = doc.getElementById("composer") as HTMLTextAreaElement;
  composer.focus();
  askPermissionFocus(performance.now() - FOCUS_REQUEST_MS - 1);
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <PermissionCard permission={permissionFromMessage(ask, "s1")!} harness="claude" onAnswer={() => undefined} />,
    );
  });
  expect(doc.activeElement).toBe(composer);
});
