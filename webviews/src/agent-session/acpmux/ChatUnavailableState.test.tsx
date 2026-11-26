import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChatUnavailableState } from "./ChatUnavailableState";
import { settleReact } from "../../../test/support/domTeardown";

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
  jest.useRealTimers();
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

test("an offline chat says Offline as a status, with no spinner", async () => {
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
        noteDelayMs={0}
      />,
    );
  });
  expect(container.querySelector('[role="status"]')).not.toBeNull();
  expect(container.querySelector('[role="alert"]')).toBeNull();
  expect(container.querySelector(".cv-spinner")).toBeNull();
  expect(container.textContent).toContain("Offline");
  expect(container.textContent).not.toContain("Reconnecting…");
});

test("an offline chat shows nothing until the drop has lasted past the threshold, then Offline", async () => {
  jest.useFakeTimers();
  const container = installDom();
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <ChatUnavailableState
        unavailable={{ reason: "offline", machine: "remote" }}
        machine="remote"
        onRemove={() => undefined}
        onReconnect={() => undefined}
        offlineDelayMs={40}
      />,
    );
  });
  expect(container.querySelector('[data-unavailable="connecting"]')).not.toBeNull();
  expect(container.textContent).toBe("");
  await act(async () => void jest.advanceTimersByTime(39));
  expect(container.querySelector('[data-unavailable="offline"]')).toBeNull();
  await act(async () => void jest.advanceTimersByTime(1));
  expect(container.querySelector('[data-unavailable="offline"]')).not.toBeNull();
  expect(container.textContent).toContain("Offline");
});

test("a machine whose link dropped says nothing for 10 s, acpmux's own redial, then Offline once", async () => {
  // Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up". Before, the state
  // showed 1.5 s into any drop, which a redial after a dead ssh link (6 s to notice, then a login)
  // always outlasts.
  jest.useFakeTimers();
  const container = installDom();
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <ChatUnavailableState
        unavailable={{ reason: "offline", machine: "remote" }}
        machine="remote"
        onRemove={() => undefined}
        onReconnect={() => undefined}
      />,
    );
  });
  await act(async () => void jest.advanceTimersByTime(9_999));
  expect(container.querySelector('[data-unavailable="offline"]')).toBeNull();
  expect(container.textContent).toBe("");
  await act(async () => void jest.advanceTimersByTime(1));
  expect(container.querySelector('[data-unavailable="offline"]')).not.toBeNull();
  expect(container.textContent).toContain("Offline");
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

async function renderPaused(container: HTMLElement, props: { resuming?: boolean; noteDelayMs?: number } = {}) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <ChatUnavailableState
        unavailable={{ reason: "paused", machine: "remote" }}
        machine="remote"
        onRemove={() => undefined}
        onReconnect={() => undefined}
        onResumeMachine={() => undefined}
        {...props}
      />,
    );
  });
}

const wait = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));

test("a paused machine shows nothing until the pause has lasted past the threshold, then a calm card", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await renderPaused(container, { noteDelayMs: 40 });
  // The first frames: the loading layout, empty, so a quick wake never flashes a card.
  expect(container.querySelector('[data-unavailable="connecting"]')).not.toBeNull();
  expect(container.textContent).toBe("");
  await wait(39);
  expect(container.querySelector('[data-unavailable="paused"]')).toBeNull();
  await wait(1);
  const card = container.querySelector('[data-unavailable="paused"]');
  expect(card).not.toBeNull();
  expect(card!.getAttribute("role")).toBe("status");
  expect(container.querySelector('[role="alert"]')).toBeNull();
  expect(container.textContent).toContain("Resume machine");
});

test("a resume keeps its spinner's slot from the first frame and fills it only past the threshold", async () => {
  const container = installDom();
  await renderPaused(container, { noteDelayMs: 0 });
  const slot = container.querySelector(".acpmux-unavailable-progress");
  expect(slot).not.toBeNull();
  expect(slot!.childElementCount).toBe(0);
  // Resuming: the slot stays empty for the threshold, then the spinner fades into it.
  await act(async () => {
    root!.render(
      <ChatUnavailableState
        unavailable={{ reason: "paused", machine: "remote" }}
        machine="remote"
        onRemove={() => undefined}
        onReconnect={() => undefined}
        onResumeMachine={() => undefined}
        resuming
        noteDelayMs={0}
      />,
    );
  });
  expect(container.querySelector(".acpmux-unavailable-progress")).toBe(slot);
  expect(slot!.querySelector(".cv-spinner")).not.toBeNull();
});

test("an offline chat reads the machines and the chat list again on its own, with no Reconnect button", async () => {
  // Leo, 2026-11-22: "vacuous decisions like that should be just done".
  jest.useFakeTimers();
  const container = installDom();
  root = createRoot(container);
  let asks = 0;
  await act(async () => {
    root!.render(
      <ChatUnavailableState
        unavailable={{ reason: "offline", machine: "remote" }}
        machine="remote"
        onRemove={() => undefined}
        onReconnect={() => asks++}
        noteDelayMs={0}
      />,
    );
  });
  expect(container.querySelector('[data-action="reconnect"]')).toBeNull();
  await act(async () => void jest.advanceTimersByTime(1_000));
  expect(asks).toBe(1);
  await act(async () => void jest.advanceTimersByTime(2_000));
  expect(asks).toBe(2);
});

test("a resume past the slow bound says it is taking longer and enables Resume machine again", async () => {
  const container = installDom();
  let clicks = 0;
  const render = (resumeLong: boolean) =>
    act(async () => {
      root ??= createRoot(container);
      root.render(
        <ChatUnavailableState
          unavailable={{ reason: "paused", machine: "remote" }}
          machine="remote"
          onRemove={() => undefined}
          onReconnect={() => undefined}
          onResumeMachine={() => void clicks++}
          onResume={() => undefined}
          resuming
          resumeLong={resumeLong}
          noteDelayMs={0}
        />,
      );
    });
  await render(false);
  const button = () => container.querySelector<HTMLButtonElement>('[data-action="resumeMachine"]')!;
  expect(button().disabled).toBe(true);
  expect(container.textContent).not.toContain("taking longer than usual");
  await render(true);
  expect(button().disabled).toBe(false);
  expect(container.textContent).toContain("This is taking longer than usual.");
  expect(container.querySelector('[data-action="resume"]')).not.toBeNull();
  // Still resuming: the spinner stays.
  expect(container.querySelector(".acpmux-unavailable-progress .cv-spinner")).not.toBeNull();
  await act(async () => button().click());
  expect(clicks).toBe(1);
});
