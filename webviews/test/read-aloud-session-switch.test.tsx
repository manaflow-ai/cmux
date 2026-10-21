// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Review of #22773 (chat hover rows): Read aloud under an answer kept speaking after the chat
// switched to another session, and that chat's button still said Stop reading when the reader came
// back. Moving the transcript to another session stops the reading.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});

// The web view's speech synthesis, stubbed: it records what is spoken and cancelled, and never
// ends an utterance on its own, as a long answer still being read.
const spoken: string[] = [];
let cancels = 0;
class Utterance {
  lang = "";
  onend: (() => void) | null = null;
  onerror: (() => void) | null = null;
  constructor(readonly text: string) {}
}
Object.defineProperty(dom.window, "speechSynthesis", {
  configurable: true,
  value: {
    speak: (utterance: Utterance) => void spoken.push(utterance.text),
    cancel: () => void cancels++,
  },
});

const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  SpeechSynthesisUtterance: Utterance,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 600 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const chat = (name: string, answer: string) => [
  row(`${name}-user`, "user", `Question in ${name}`),
  row(`${name}-answer`, "assistant", answer),
  { ...row(`${name}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
];
const chatA = chat("a", "The hosted test run is still queued behind two other jobs.");
const chatB = chat("b", "The PR checks passed.");

/// The Read aloud button under the shown answer, by what it says now.
const readAloudButton = () =>
  dom.window.document.querySelector<HTMLButtonElement>(
    'button[aria-label="Read aloud"], button[aria-label="Stop reading"]',
  );

test("switching the chat to another session stops reading the answer aloud", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const show = (sessionId: string, rows: AcpmuxRow[]) =>
    root.render(
      <VirtualTranscript
        rows={turnView(rows, new Set())}
        sessionId={sessionId}
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    );
  try {
    await act(async () => show("chat-a", chatA));
    const button = readAloudButton();
    expect(button).not.toBeNull();
    await act(async () => button!.click());
    expect(spoken).toEqual(["The hosted test run is still queued behind two other jobs."]);
    expect(readAloudButton()?.getAttribute("aria-label")).toBe("Stop reading");
    const cancelsWhileReading = cancels;

    // The chat moves to another session: the first chat's answer stops being read.
    await act(async () => show("chat-b", chatB));
    expect(cancels).toBeGreaterThan(cancelsWhileReading);

    // Back on the first chat, its answer is not being read.
    await act(async () => show("chat-a", chatA));
    expect(readAloudButton()?.getAttribute("aria-label")).toBe("Read aloud");
    expect(readAloudButton()?.getAttribute("aria-pressed")).toBe("false");
    expect(spoken).toHaveLength(1);
  } finally {
    await act(async () => root.unmount());
  }
});
