// l10n-allow-file: test fixtures.
// The person's own status line under the composer (Settings > Status Line Command,
// `agentPane.statusLine.command`; ComposerStatusLine.tsx):
//   - unset (acpmux answers no line, the default) nothing draws: the composer is as it was;
//   - a line draws once the chat's state settles, and is asked for again only when that state
//     changes (a turn ends), never on a timer;
//   - a switch to another chat drops the old chat's line at once.
import { afterAll, afterEach, beforeAll, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import React, { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import {
  ComposerStatusLine,
  STATUS_LINE_SETTLE_MS,
  useComposerStatusLine,
  type AskStatusLine,
} from "../src/agent-session/acpmux/ComposerStatusLine";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT", "HTMLElement", "Node"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node,
  });
  host = dom.window.document.getElementById("root")!;
});

beforeEach(() => {
  jest.useFakeTimers();
});

afterEach(() => {
  act(() => root?.unmount());
  jest.useRealTimers();
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Probe({ ask, sessionId, state }: { ask: AskStatusLine; sessionId: string; state: string }) {
  const line = useComposerStatusLine(ask, sessionId, state);
  return line ? <ComposerStatusLine line={line} /> : null;
}

// Fake timers: the settle delay is the behavior under test, so the test moves the clock past it.
async function pastSettle() {
  await act(async () => {
    jest.advanceTimersByTime(STATUS_LINE_SETTLE_MS + 30);
  });
  await act(async () => {});
}

function shown(): string | null {
  return host.querySelector("[data-composer-status-line]")?.textContent ?? null;
}

async function draw(ask: AskStatusLine, sessionId: string, state: string) {
  root ??= createRoot(host);
  await act(async () => root!.render(<Probe ask={ask} sessionId={sessionId} state={state} />));
}

test("no command set: acpmux answers no line and nothing draws", async () => {
  const asked: string[] = [];
  await draw(
    async (id) => {
      asked.push(id);
      return undefined;
    },
    "chat-1",
    "idle|0",
  );
  await pastSettle();
  expect(asked).toEqual(["chat-1"]);
  expect(shown()).toBeNull();
  expect(host.innerHTML).toBe("");
});

test("the line draws, and is asked for again only when the chat's state changes", async () => {
  let turn = 0;
  const asked: string[] = [];
  const ask: AskStatusLine = async (id) => {
    asked.push(id);
    return `main +${turn}`;
  };
  await draw(ask, "chat-1", "idle|0");
  await pastSettle();
  expect(shown()).toBe("main +0");
  const line = host.querySelector(".acpmux-composer-status-line");
  expect(line?.getAttribute("title")).toBe("main +0");

  // The same state again asks nothing: no timer.
  await draw(ask, "chat-1", "idle|0");
  await pastSettle();
  await pastSettle();
  expect(asked).toEqual(["chat-1"]);

  turn = 1;
  await draw(ask, "chat-1", "idle|1");
  await pastSettle();
  expect(asked).toEqual(["chat-1", "chat-1"]);
  expect(shown()).toBe("main +1");
});

test("a switch to another chat drops the old chat's line at once", async () => {
  const ask: AskStatusLine = async (id) => (id === "chat-1" ? "first chat" : undefined);
  await draw(ask, "chat-1", "idle|0");
  await pastSettle();
  expect(shown()).toBe("first chat");
  await draw(ask, "chat-2", "idle|0");
  expect(shown()).toBeNull();
  await pastSettle();
  expect(shown()).toBeNull();
});
