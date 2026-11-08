import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChatUnavailableState } from "./ChatUnavailableState";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
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

test("an offline chat uses a neutral status spinner", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <ChatUnavailableState
        unavailable={{ reason: "offline", machine: "remote" }}
        session="session-id"
        machine="remote"
        onRemove={() => undefined}
        onReconnect={() => undefined}
        onResume={() => undefined}
        onClose={() => undefined}
      />,
    );
  });
  expect(container.querySelector('[role="status"]')).not.toBeNull();
  expect(container.querySelector('[role="alert"]')).toBeNull();
  expect(container.querySelector(".cv-spinner")).not.toBeNull();
  expect(container.textContent).toContain("Reconnecting…");
});

test("a chat still connecting shows nothing: no spinner, no text, no buttons", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <ChatUnavailableState
        unavailable={{ reason: "connecting", machine: "remote" }}
        session="session-id"
        machine="remote"
        onRemove={() => undefined}
        onReconnect={() => undefined}
        onResume={() => undefined}
        onClose={() => undefined}
      />,
    );
  });
  const area = container.querySelector('[data-unavailable="connecting"]');
  expect(area).not.toBeNull();
  expect(area!.childElementCount).toBe(0);
  expect(container.textContent).toBe("");
  expect(container.querySelector(".cv-spinner")).toBeNull();
  expect(container.querySelector("[role]")).toBeNull();
});

test("deleted chats remain a terminal alert without a reconnect spinner", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ChatUnavailableState
        unavailable={{ reason: "deleted", machine: "remote" }}
        onRemove={() => undefined}
        onReconnect={() => undefined}
      />,
    );
  });
  expect(container.querySelector('[role="alert"]')).not.toBeNull();
  expect(container.querySelector(".cv-spinner")).toBeNull();
  expect(container.textContent).toContain("This chat was deleted");
});
