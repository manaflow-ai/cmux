// A New Tab page with typed text, replaced by the chat view before the handshake (the host failed
// to hand the pane acpmux): the chat view's composer keeps what was typed, and the page that comes
// back once the host answers takes it back. Before, onLeaveDraft dropped it unless a Sandboxed run
// took the view, and the classic page had no handoff at all (cmux#28204 review).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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
  // jsdom lays nothing out and its Range has no rects: ProseMirror measures one to scroll.
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
  delete (dom.window as unknown as { __cmuxNewTabContext?: unknown }).__cmuxNewTabContext;
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

type FieldElement = HTMLElement & {
  acpmuxMarkdownField?: { value(): string; type(text: string): unknown };
};
const promptField = () => {
  const element = host.querySelector<FieldElement>(".acpmux-composer-prompt");
  return element?.querySelector("[contenteditable]") ? element.acpmuxMarkdownField : undefined;
};
const composerText = () => promptField()?.value() ?? "";

/// The pane on a host whose `ready` fails until `answer()` is called; then it answers with the
/// in-page mock daemon. The page draws its New Tab frame from the injected context first.
async function mount(template: "classic" | "default") {
  let answers = false;
  // The first `ready` waits until `fail()`: the page is up and typed into before the host fails.
  let failFirst: (() => void) | undefined;
  let asked = 0;
  const newTab = { template, cwd: "/tmp/draft-project", projects: ["/tmp/draft-project"] };
  Object.assign(dom.window, {
    __cmuxNewTabContext: newTab,
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string; params?: Record<string, unknown> }) => {
            const refusal = { ok: false, error: { code: "acpmux.unavailable", message: "acpmux is not installed" } };
            if (message.method === "ready" && !answers) {
              asked += 1;
              if (asked > 1) return Promise.resolve(refusal);
              return new Promise((done) => (failFirst = () => done(refusal)));
            }
            return Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? { protocolVersion: 1, transport: "mock", newSession: true, machineName: "Mac", newTab }
                  : message.method === "newTab.context"
                    ? { newTab }
                    : undefined,
            });
          },
        },
      },
    },
  });
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  return {
    fail: () => failFirst?.(),
    answer: () => {
      answers = true;
    },
  };
}

function typeInto(field: FieldElement, text: string) {
  if (field.acpmuxMarkdownField) {
    field.acpmuxMarkdownField.type(text);
    return;
  }
  const input = field as HTMLInputElement;
  const proto =
    input instanceof dom.window.HTMLTextAreaElement ? dom.window.HTMLTextAreaElement : dom.window.HTMLInputElement;
  Object.getOwnPropertyDescriptor(proto.prototype, "value")!.set!.call(input, text);
  input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
}

const fieldValue = (field: FieldElement) => field.acpmuxMarkdownField?.value() ?? (field as HTMLInputElement).value;

for (const [template, selector] of [
  ["default", ".nt-field"],
  ["classic", ".acpmux-newtab-field"],
] as const) {
  test(`${template} New Tab: text typed before a failed handshake moves to the chat composer and back`, async () => {
    const pane = await mount(template);
    const draft = template === "default" ? "Keep **bold** and \\_literal\\_" : "draft typed before the handshake";
    // The page draws before the handshake; the person types into it at once.
    const field = () => host.querySelector<FieldElement>(selector);
    await until(() => field() !== null, "the New Tab page draws before the handshake");
    await until(
      () => template === "classic" || !!field()?.querySelector("[contenteditable]"),
      "the New Tab editor is ready",
    );
    await act(async () => typeInto(field()!, draft));
    expect(fieldValue(field()!)).toBe(draft);

    // The host fails before its handshake: the chat view (error card and composer) takes the page's
    // place, and its composer keeps the typed text.
    await act(async () => pane.fail());
    await until(() => field() === null && promptField() !== undefined, "the chat view stands in for the page");
    await until(() => composerText() === draft, "the composer keeps the draft");

    // The host answers a retry: the page comes back with the draft.
    pane.answer();
    await until(() => field() !== null, "the New Tab page comes back after the handshake", 30_000);
    await until(() => fieldValue(field()!) === draft, "the page restores the serialized draft");
  }, 60_000);
}

test("an existing chat that failed before its handshake and recovered gives a later New Tab no prompt", async () => {
  // cmux#28204 review: the stand-in flag stayed set after a chat's own recovery, and a New Tab
  // adopted into the pane later took the chat's prompt as its draft.
  let answers = false;
  let failFirst: (() => void) | undefined;
  let asked = 0;
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string }) => {
            const refusal = { ok: false, error: { code: "acpmux.unavailable", message: "acpmux is not installed" } };
            if (message.method === "ready" && !answers) {
              asked += 1;
              if (asked > 1) return Promise.resolve(refusal);
              return new Promise((done) => (failFirst = () => done(refusal)));
            }
            return Promise.resolve({
              ok: true,
              value:
                message.method === "ready"
                  ? { protocolVersion: 1, transport: "mock", newSession: true, machineName: "Mac" }
                  : undefined,
            });
          },
        },
      },
    },
  });
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await until(() => failFirst !== undefined, "the handshake goes out");
  await act(async () => failFirst!());
  await until(() => promptField() !== undefined, "the chat view with its error card");
  answers = true;
  await until(
    () => (dom.window as unknown as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions !== undefined,
    "the chat recovers",
    30_000,
  );
  // The person types in the chat's own composer.
  const field = host.querySelector<HTMLElement & { acpmuxMarkdownField?: { type(text: string): unknown } }>(
    ".acpmux-composer-prompt",
  )!;
  await act(async () => void field.acpmuxMarkdownField!.type("the chat's own prompt"));
  await until(() => composerText() === "the chat's own prompt", "the chat's prompt");
  // Cmd-T adopts a New Tab into this pane: it opens empty.
  const { NEW_TAB_ADOPT_EVENT } = await import("../src/agent-session/acpmux/newtab/adoption");
  await act(async () =>
    dom.window.dispatchEvent(
      new dom.window.CustomEvent(NEW_TAB_ADOPT_EVENT, {
        detail: { template: "default", cwd: "/tmp/draft-project", projects: ["/tmp/draft-project"] },
      }),
    ),
  );
  await until(() => host.querySelector(".nt-field") !== null, "the New Tab page");
  expect(fieldValue(host.querySelector<FieldElement>(".nt-field")!)).toBe("");
}, 60_000);
