// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo, 2026-11-09: "I can't click into the composer at all to, like potentially type other stuff
// while it's doing that initial load situation." Once a Cloud start stalls the composer is the
// person's again (composer-cloud-start-stall.test.tsx); if the start then opens its chat after all,
// the host closes this tab, so what they typed goes with the start, under its key
// (`cloud.startChat {key}`), to the opened chat, whose handshake names the same key
// (`cloudStartKey`). Keyed by the start, never the prompt: two starts with the same prompt keep
// their own drafts, and an attachment-only draft carries as well. A failed start keeps its draft
// here and carries none.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import {
  cloudStartCarry,
  cloudStartCarrySource,
  type CloudStartCarryStore,
} from "../src/agent-session/acpmux/cloudStartCarry";

function memoryStore(): CloudStartCarryStore & { full?: boolean } {
  const items = new Map<string, string>();
  const store = {
    full: false,
    getItem: (name: string) => items.get(name) ?? null,
    setItem(name: string, value: string) {
      if (store.full && value.includes('"data"')) throw new Error("QuotaExceededError");
      items.set(name, value);
    },
  };
  return store;
}

const image: ComposerAttachment = {
  id: "img-1",
  kind: "image",
  name: "shot.png",
  mimeType: "image/png",
  size: 4,
  data: "AAAA",
};
const sent = { text: "fix the build", attachments: [] };

/// A stalled start on one tab, the person typing `typed` after the stall, then the host's answer.
function stallThenType(
  store: CloudStartCarryStore,
  key: string,
  typed: { text: string; attachments: ComposerAttachment[] },
) {
  const source = cloudStartCarrySource(cloudStartCarry(store));
  // At the stall the composer still holds the sent prompt: it is taken out and held for a failure.
  expect(source.stalled(key, sent, sent)).toEqual(sent);
  source.edited(() => ({ text: "", attachments: [] }));
  source.edited(() => typed);
  return source;
}

test("text typed after a stall goes to the chat the start opens, once", () => {
  const store = memoryStore();
  const source = stallThenType(store, "k-1", { text: "also check the dock", attachments: [] });
  // A late success: the host opened the chat and closes this tab.
  source.ended("k-1", true);
  const destination = cloudStartCarry(store);
  expect(destination.take("k-1")).toEqual({ text: "also check the dock", attachments: [] });
  expect(destination.take("k-1")).toBeUndefined();
});

test("attachments typed after a stall go with their text", () => {
  const store = memoryStore();
  const typed = { text: "see ￼", attachments: [{ ...image, inline: true }] };
  stallThenType(store, "k-1", typed).ended("k-1", true);
  expect(cloudStartCarry(store).take("k-1")).toEqual(typed);
});

test("an attachment-only draft carries", () => {
  const store = memoryStore();
  const typed = { text: "", attachments: [image] };
  stallThenType(store, "k-1", typed).ended("k-1", true);
  expect(cloudStartCarry(store).take("k-1")).toEqual(typed);
});

test("two starts with the same prompt keep their own drafts", () => {
  const store = memoryStore();
  stallThenType(store, "k-1", { text: "first tab's words", attachments: [] }).ended("k-1", true);
  stallThenType(store, "k-2", { text: "second tab's words", attachments: [] }).ended("k-2", true);
  const destination = cloudStartCarry(store);
  expect(destination.take("k-2")?.text).toBe("second tab's words");
  expect(destination.take("k-1")?.text).toBe("first tab's words");
});

test("a failed start keeps its draft here and carries none", () => {
  const store = memoryStore();
  const source = stallThenType(store, "k-1", { text: "typed after", attachments: [] });
  source.ended("k-1", false);
  expect(cloudStartCarry(store).take("k-1")).toBeUndefined();
  // Another start's answer, or edits after it ended, change nothing.
  source.ended("k-2", true);
  source.edited(() => ({ text: "late", attachments: [] }));
  expect(cloudStartCarry(store).take("k-1")).toBeUndefined();
});

test("a page's start, whose chat composer is not its prompt, carries what is there from the stall", () => {
  const store = memoryStore();
  const source = cloudStartCarrySource(cloudStartCarry(store));
  expect(source.stalled("k-1", { text: "", attachments: [] }, { text: "", attachments: [] })).toBeUndefined();
  source.edited(() => ({ text: "next", attachments: [] }));
  source.ended("k-1", true);
  expect(cloudStartCarry(store).take("k-1")?.text).toBe("next");
});

test("a store too full for the files' bytes still carries the text", () => {
  const store = memoryStore();
  store.full = true;
  stallThenType(store, "k-1", { text: "words", attachments: [image] }).ended("k-1", true);
  expect(cloudStartCarry(store).take("k-1")).toEqual({ text: "words", attachments: [] });
});

// The opened chat's page: its handshake names the start's key, and its composer gets the carry.
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    location: dom.window.location,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    Element: dom.window.Element,
    Event: dom.window.Event,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia });
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(async () => {
  (await import("../src/agent-session/acpmux/newtab/chatStore")).markMockPage(false);
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

const tick = () =>
  act(async () => {
    await new Promise((done) => setTimeout(done, 0));
  });
async function until(check: () => boolean, what: string, within = 15_000) {
  const deadline = Date.now() + within;
  while (!check() && Date.now() < deadline) await tick();
  expect(check(), what).toBe(true);
}

const composerText = () =>
  host
    .querySelector<HTMLElement & { acpmuxMarkdownField?: { value(): string } }>(".acpmux-composer-prompt")
    ?.acpmuxMarkdownField?.value() ?? "";

async function openChat(cloudStartKey: string | undefined) {
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string }) =>
            Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? {
                      protocolVersion: 1,
                      transport: "mock",
                      newSession: true,
                      machineName: "paint-dev",
                      ...(cloudStartKey ? { cloudStartKey } : {}),
                    }
                  : undefined,
            }),
        },
      },
    },
  });
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
}

test("typing after a stall survives a late success: the opened chat's composer holds it", async () => {
  // The first tab: the start stalled, the person typed, then the chat opened after all.
  stallThenType(dom.window.localStorage, "k-late", { text: "and update the docs", attachments: [] }).ended(
    "k-late",
    true,
  );
  // The chat that start opened on its machine.
  await openChat("k-late");
  await until(() => composerText() === "and update the docs", "the opened chat's composer holds the carried draft");
  // Taken once: a reload of the page gets nothing again.
  expect(cloudStartCarry(dom.window.localStorage).take("k-late")).toBeUndefined();
}, 60_000);

test("a chat another start opened takes no one else's draft", async () => {
  stallThenType(dom.window.localStorage, "k-mine", { text: "mine", attachments: [] }).ended("k-mine", true);
  await openChat("k-other");
  await until(() => host.querySelector(".acpmux-composer-prompt") !== null, "the composer");
  await tick();
  expect(composerText()).toBe("");
  expect(cloudStartCarry(dom.window.localStorage).take("k-mine")?.text).toBe("mine");
}, 60_000);
