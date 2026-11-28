// "Just go" (Leo, 2026-11-25: "playable vs fully installed/downloaded. do we want loading
// indicators? or just go"): the composer takes Return while a Cloud chat starts. The message
// queues for the started chat's first prompt (App.tsx queueCloudStartSend, host
// `chat.cloudStartQueue`) and the composer empties, as a send does.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "KeyboardEvent",
  "InputEvent",
  "MouseEvent",
  "CompositionEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    MouseEvent: window.MouseEvent,
    CompositionEvent: window.CompositionEvent,
  });
  // jsdom lays nothing out: a range has no boxes, which ProseMirror reads to scroll the caret into view.
  const box = { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0 };
  Object.assign(window.Range.prototype, { getClientRects: () => [], getBoundingClientRect: () => box });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

function chat(): AcpmuxSnapshot {
  return noChat([], { rows: [user("Add retries", 1)] });
}

async function composer(typed: string, queue?: (text: string) => boolean) {
  const sent: string[] = [];
  let handle: ComposerHandle | null = null;
  const snapshot = chat();
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        handle={(value) => void (handle = value)}
        snapshot={snapshot}
        chips={Chips}
        cloudStarting
        {...(queue ? { onCloudStartQueue: queue } : {})}
        onSend={(text) => {
          sent.push(text);
          return true;
        }}
        onStop={() => {}}
        localName="studio"
      />,
    ),
  );
  await act(async () => handle!.restore(typed, []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  const enter = () =>
    act(async () => {
      field.dispatchEvent(
        new window.KeyboardEvent("keydown", { key: "Enter", keyCode: 13, bubbles: true, cancelable: true }),
      );
    });
  return { sent, enter, draft: () => handle!.draft().text };
}

test("Return during a Cloud start queues the message for the started chat and empties the composer", async () => {
  const queued: string[] = [];
  const { sent, enter, draft } = await composer("and run the tests", (text) => {
    queued.push(text);
    return true;
  });
  await enter();
  expect(queued).toEqual(["and run the tests"]);
  expect(sent).toEqual([]);
  expect(draft()).toBe("");
});

test("a queue that refuses (the kill switch) keeps the draft and sends nothing", async () => {
  const { sent, enter, draft } = await composer("and run the tests", () => false);
  await enter();
  expect(sent).toEqual([]);
  expect(draft()).toBe("and run the tests");
});

test("with no queue, Return during a start still waits", async () => {
  const { sent, enter, draft } = await composer("and run the tests");
  await enter();
  expect(sent).toEqual([]);
  expect(draft()).toBe("and run the tests");
});
