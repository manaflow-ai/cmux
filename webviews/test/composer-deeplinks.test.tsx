// cmux deeplinks in the composer (Leo, 2026-11-03: "hm i wonder if those should be rendered the
// deeplinks within the composer too..."): a workspace or agent link in the draft draws as a link
// (composer/deeplinkTokens.ts), its text kept, so Send sends exactly the URL that was typed; a sent
// prompt draws a cmux app link as a link too (conversation/PromptText.tsx).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { deeplinks } from "../src/agent-session/acpmux/composer/deeplinks";
import { PromptTyped } from "../src/agent-session/acpmux/conversation/PromptText";

const WORKSPACE = "cmux-nightly://workspace/ws_cca525bafd4d2b969dad8fdb549b0c61";
const AGENT = "cmux://agent/claude/9b2f4c1e-5d7a-4e3b-8c6f-1a2b3c4d5e6f";
const WEB_AGENT = "https://cmux.com/deeplink/agent?harness=claude&session=9b2f4c1e";

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

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

let chats = 0;

function chat(): AcpmuxSnapshot {
  const sessionId = `deeplinks-${++chats}`;
  return noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
  });
}

async function composer(typed: string) {
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
        sessionId={snapshot.sessionId}
        chips={Chips}
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
  return { field, sent };
}

const linked = () => [...host.querySelectorAll(".acpmux-deeplink.is-link")].map((node) => node.textContent);

test("deeplinks finds cmux app links and cmux.com deeplinks, and nothing else", () => {
  const text = `see ${WORKSPACE}, then ${AGENT}. Or ${WEB_AGENT} and https://example.com/deeplink/x`;
  expect(deeplinks(text).map((link) => text.slice(link.start, link.end))).toEqual([WORKSPACE, AGENT, WEB_AGENT]);
  expect(deeplinks("cmux:/workspace javascript://x src/cmux://y cmux://nope/x")).toEqual([]);
});

test("a deeplink in the draft draws as a link and sends exactly as typed", async () => {
  const typed = `Open ${WORKSPACE} and the chat at ${AGENT}.`;
  const { field, sent } = await composer(typed);
  expect(linked()).toEqual([WORKSPACE, AGENT]);
  await act(async () => {
    field.dispatchEvent(
      new window.KeyboardEvent("keydown", { key: "Enter", keyCode: 13, bubbles: true, cancelable: true }),
    );
  });
  expect(sent).toEqual([typed]);
});

test("a draft with no deeplink draws none", async () => {
  await composer("Fix https://example.com/x and cmux:/workspace");
  expect(linked()).toEqual([]);
});

test("a sent prompt draws a cmux app link as a link the app opens", () => {
  const html = renderToStaticMarkup(<PromptTyped text={`Open ${WORKSPACE} now`} show={(text) => text} />);
  expect(html).toContain(`class="cv-link is-app" href="${WORKSPACE}"`);
});
