// Another agent's message is one line whether or not cmux's Minimal Mode is on
// (conversation/IncomingMessageCard.tsx; Leo 2026-10-24: "we could just have the first line be the
// thing that's there, and then you can expand that", and 2026-10-29: "why the fuck did you guys
// ffucking ellipsis EVERYTHING WITH NO WAY TO EXPAND WHAT WAS SAID TO SEE"): the sender's name, then
// the message's first line, with no "Received message from" lead. The line opens the sender's chat;
// its chevron, the shared DisclosureRow's toggle, opens the whole message in place and closes it again.
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
  const toggle = () => host.querySelector<HTMLButtonElement>("button.cv-disclosure__toggle")!;
  // The sender's name opens its chat (Leo, 2026-10-29: "Just click the left name thing"); no Open chat.
  return { opened, toggle, open: host.querySelector<HTMLButtonElement>("button.cv-received__from--open")! };
}

test("Minimal Mode follows only cmux's own Minimal Mode switch", () => {
  expect(DEFAULT_CHAT_DISPLAY.minimal).toBe(false);
  expect(resolveChatDisplay({ [MINIMAL_MODE_KEY]: true }).minimal).toBe(true);
  expect(resolveChatDisplay({ [MINIMAL_MODE_KEY]: "yes" }).minimal).toBe(false);
  expect(resolveChatDisplay({}).minimal).toBe(false);
});

for (const minimal of [false, true])
  test(`with Minimal Mode ${minimal ? "on" : "off"} the message is one line: its name, then its first line; its chevron opens and closes it`, async () => {
    if (minimal) setChatDisplay({ [MINIMAL_MODE_KEY]: true });
    const { open, opened, toggle } = await line(`line-${minimal}`);
    // The name and the first line of text, as it reads, and nothing under the line.
    expect(host.querySelector(".cv-received__from")?.textContent).toBe("grid-lane");
    expect(host.querySelector(".cv-received__preview")?.textContent).toBe("Rebased onto main; ready for review.");
    expect(host.textContent).not.toContain("Received message from");
    expect(host.querySelector(".cv-received__text")).toBeNull();
    expect(host.querySelector(".cv-disclosure__panel")).toBeNull();
    expect(toggle().tagName).toBe("BUTTON");
    expect(toggle().getAttribute("aria-expanded")).toBe("false");
    expect(toggle().getAttribute("aria-label")).toBe(
      t("message.collapsedLabel", { from: "grid-lane", preview: "Rebased onto main; ready for review." }),
    );
    expect(host.querySelector(".cv-disclosure__open")).toBeNull();
    // The name opens the sender's chat, and leaves the message closed.
    await act(async () => open.click());
    expect(opened).toEqual(["mux-grid"]);
    expect(host.querySelector(".cv-received__text")).toBeNull();
    // The line opens the whole message in place, with no From: line repeating the name above it.
    await act(async () => toggle().click());
    expect(toggle().getAttribute("aria-expanded")).toBe("true");
    expect(host.querySelector(".cv-received__from-line")).toBeNull();
    expect(host.querySelector(".cv-received__text")?.textContent).toContain("The retry tests pass.");
    expect(host.querySelector(".cv-received__text")?.textContent).toContain("CI is green.");
    expect(host.querySelector(".cv-received__body, [data-cut], .cv-received__show")).toBeNull();
    const panel = host.querySelector(".cv-disclosure__panel")!;
    expect(toggle().getAttribute("aria-controls")).toBe(panel.parentElement!.id);
    // And closes it again (a page with no Web Animations closes at once); the line stays as it was.
    await act(async () => toggle().click());
    expect(toggle().getAttribute("aria-expanded")).toBe("false");
    expect(host.querySelector(".cv-received__text")).toBeNull();
    expect(host.querySelector(".cv-received__preview")?.textContent).toBe("Rebased onto main; ready for review.");
  });

test("switching Minimal Mode leaves a closed message its one line", async () => {
  setChatDisplay({ [MINIMAL_MODE_KEY]: true });
  await line("minimal-2");
  expect(host.querySelector(".cv-received__text")).toBeNull();
  await act(async () => setChatDisplay({}));
  expect(host.querySelector(".cv-received__text")).toBeNull();
  expect(host.querySelector(".cv-received__preview")?.textContent).toBe("Rebased onto main; ready for review.");
});

test("the reader's toggle plays the fold: the panel's height grows on open and closing fades out", async () => {
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
    const { toggle } = await line("fold-1");
    await act(async () => toggle().click());
    expect(frames.length).toBeGreaterThan(0);
    expect(frames.at(-1)!.some((frame) => frame.height !== undefined)).toBe(true);
    await act(async () => toggle().click());
    expect(frames.at(-1)!.map((frame) => frame.opacity)).toEqual([1, 0]);
  } finally {
    delete proto.animate;
    Object.assign(foldMotion, motion);
  }
});

test("a closed message estimates as its line in either mode; one opened in this chat as its whole panel", async () => {
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
    expect(height("chat-a")).toBe(normal);
    setMessageOpened("chat-a", "estimate-1", true);
    // Opened: the whole text, its fourteen lines; another chat's row of the same id stays closed.
    expect(height("chat-a")).toBeGreaterThan(normal + 13 * 16);
    expect(height("chat-b")).toBe(normal);
  } finally {
    setMessageOpened("chat-a", "estimate-1", false);
  }
});
