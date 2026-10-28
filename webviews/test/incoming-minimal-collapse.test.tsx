// In cmux's Minimal Mode another agent's message is one line (conversation/IncomingMessageCard.tsx;
// Leo 2026-10-24: "we could just have the first line be the thing that's there, and then you can
// expand that"): the sender's chip, which still opens its chat, then the message's first line, with
// no "Received message from" lead. The line is a button that opens the card in place and closes it
// again; with Minimal Mode off the message draws as before.
import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import { DEFAULT_CHAT_DISPLAY, MINIMAL_MODE_KEY, resolveChatDisplay } from "../src/agent-session/acpmux/chatDisplay";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Range: dom.window.Range,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|CustomEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

const { createRoot } = await import("react-dom/client");
const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { setChatDisplay } = await import("../src/agent-session/acpmux/chatDisplay");

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  setChatDisplay({});
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const t = translatorFor("en");
const text =
  "\n**Rebased** onto [main](https://example.com/main); ready for review.\n\nThe retry tests pass.\nCI is green.";

async function line(id: string) {
  const opened: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <IncomingMessageLine
        id={id}
        message={{ name: "grid-lane", sessionId: "mux-grid", text, raw: text }}
        onOpen={(sessionId) => void opened.push(sessionId)}
      />,
    ),
  );
  const toggle = () => host.querySelector<HTMLButtonElement>("button.cv-received__toggle")!;
  return { opened, toggle, chip: host.querySelector<HTMLButtonElement>("button.cv-received__name")! };
}

test("Minimal Mode follows only cmux's own Minimal Mode switch", () => {
  expect(DEFAULT_CHAT_DISPLAY.minimal).toBe(false);
  expect(resolveChatDisplay({ [MINIMAL_MODE_KEY]: true }).minimal).toBe(true);
  expect(resolveChatDisplay({ [MINIMAL_MODE_KEY]: "yes" }).minimal).toBe(false);
  expect(resolveChatDisplay({}).minimal).toBe(false);
});

test("with Minimal Mode off the message draws as before: its line over the whole card", async () => {
  const { toggle } = await line("normal-1");
  expect(host.querySelector(".cv-received__preview")).toBeNull();
  expect(host.querySelector(".cv-received__body")?.textContent).toContain("The retry tests pass.");
  expect(host.querySelector(".cv-received[data-minimal]")).toBeNull();
  expect(toggle().getAttribute("aria-label")).toBe(t("message.label", { from: "grid-lane", to: t("message.self") }));
  expect(toggle().getAttribute("aria-expanded")).toBe("false");
});

test("in Minimal Mode the message is one line: the chip, then its first line, which opens and closes it", async () => {
  setChatDisplay({ [MINIMAL_MODE_KEY]: true });
  const { chip, opened, toggle } = await line("minimal-1");
  // The chip and the first line of text, as it reads, and nothing under the line.
  expect(chip.textContent).toBe("grid-lane");
  expect(host.querySelector(".cv-received__preview")?.textContent).toBe("Rebased onto main; ready for review.");
  expect(host.textContent).not.toContain("Received message from");
  expect(host.querySelector(".cv-received__body")).toBeNull();
  expect(toggle().tagName).toBe("BUTTON");
  expect(toggle().getAttribute("aria-expanded")).toBe("false");
  expect(toggle().getAttribute("aria-label")).toBe(
    t("message.collapsedLabel", { from: "grid-lane", preview: "Rebased onto main; ready for review." }),
  );
  // The chip still opens the sender's chat, and leaves the message closed.
  await act(async () => chip.click());
  expect(opened).toEqual(["mux-grid"]);
  expect(host.querySelector(".cv-received__body")).toBeNull();
  // The line opens the whole card in place.
  await act(async () => toggle().click());
  expect(toggle().getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-received__preview")).toBeNull();
  expect(host.querySelector(".cv-received__body")?.textContent).toContain("CI is green.");
  expect(toggle().getAttribute("aria-controls")).toBe(host.querySelector(".cv-received__body")!.id);
  // And closes it again (a page with no Web Animations closes at once).
  await act(async () => toggle().click());
  expect(toggle().getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelector(".cv-received__body")).toBeNull();
  expect(host.querySelector(".cv-received__preview")?.textContent).toBe("Rebased onto main; ready for review.");
});

test("turning Minimal Mode off draws the closed message's card again", async () => {
  setChatDisplay({ [MINIMAL_MODE_KEY]: true });
  await line("minimal-2");
  expect(host.querySelector(".cv-received__body")).toBeNull();
  await act(async () => setChatDisplay({}));
  expect(host.querySelector(".cv-received__preview")).toBeNull();
  expect(host.querySelector(".cv-received__body")?.textContent).toContain("The retry tests pass.");
});

test("the line opens with no fade-in, its height alone moving; closing fades out", async () => {
  const { foldMotion } = await import("../src/agent-session/acpmux/conversation/fold");
  const motion = { ...foldMotion };
  const proto = dom.window.HTMLElement.prototype as unknown as { animate?: unknown };
  const frames: Keyframe[][] = [];
  proto.animate = (keyframes: Keyframe[]) => {
    frames.push(keyframes);
    return { onfinish: null, oncancel: null, cancel() {} };
  };
  Object.assign(foldMotion, { duration: () => 180, reducedMotion: () => false });
  try {
    setChatDisplay({ [MINIMAL_MODE_KEY]: true });
    const { toggle } = await line("minimal-3");
    await act(async () => toggle().click());
    expect(frames.at(-1)!.map((frame) => frame.opacity)).toEqual([1, 1]);
    await act(async () => toggle().click());
    expect(frames.at(-1)!.map((frame) => frame.opacity)).toEqual([1, 0]);
  } finally {
    delete proto.animate;
    Object.assign(foldMotion, motion);
  }
});

test("in Minimal Mode a closed message estimates as its line; one opened in this chat as its whole card", async () => {
  const { layoutConversation } = await import("../src/agent-session/acpmux/model");
  const { setMessageOpened } = await import("../src/agent-session/acpmux/conversation/incomingOpened");
  const long = Array.from({ length: 14 }, (_, index) => `Line ${index + 1} of the landing report.`).join("\n");
  const row = {
    id: "estimate-1",
    version: 1,
    at: 0,
    kind: "user",
    text: long,
    incoming: { kind: "message", message: { name: "grid-lane", text: long, raw: long } },
  };
  const height = (sessionId: string) =>
    layoutConversation([row] as never, 720, new Map(), undefined, undefined, undefined, sessionId).heights[0]!;
  const normal = height("chat-a");
  setChatDisplay({ [MINIMAL_MODE_KEY]: true });
  try {
    const closed = height("chat-a");
    expect(closed).toBeLessThan(normal);
    setMessageOpened("chat-a", "estimate-1", true);
    // Opened: the whole card, longer than normal mode's eight-line cut; another chat's row of the
    // same id stays closed.
    expect(height("chat-a")).toBeGreaterThan(normal);
    expect(height("chat-b")).toBe(closed);
  } finally {
    setMessageOpened("chat-a", "estimate-1", false);
  }
});
