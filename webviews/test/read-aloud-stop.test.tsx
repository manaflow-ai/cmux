// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// User, 2026-10-29: "I clicked the speaker button to read a message out loud and now I can't stop
// it." The page spoke through its own web view: a WebKit chat closed (or hibernated) while reading
// kept talking, and no page, palette, CLI or MCP call could reach that voice again; the button
// under the answer also looked the same while reading and hid with its row once the pointer left.
// The app now owns the voice (AgentPaneReadAloud): the page asks it to speak and stop, and draws
// the app's state.
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
  KeyboardEvent: dom.window.KeyboardEvent,
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
const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const rows = [
  row("q1", "user", "First question"),
  row("a1", "assistant", "The **hosted** test run is still queued behind two other jobs."),
  { ...row("e1", "turnSummary"), status: "completed", durationMs: 1_000 },
  row("q2", "user", "Second question"),
  row("a2", "assistant", "The PR checks passed."),
  { ...row("e2", "turnSummary"), status: "completed", durationMs: 1_000 },
];

const buttons = () => [
  ...dom.window.document.querySelectorAll<HTMLButtonElement>(
    'button[aria-label="Read aloud"], button[aria-label="Stop reading"]',
  ),
];
const label = (button: HTMLButtonElement | undefined) => button?.getAttribute("aria-label");
const escape = () =>
  dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));

async function withTranscript(body: () => Promise<void>) {
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId="chat"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    await body();
  } finally {
    await act(async () => root.unmount());
  }
}

test("while it reads, the button shows Stop and keeps its row shown; a second press stops it", async () => {
  await withTranscript(async () => {
    const [first] = buttons();
    expect(first).toBeDefined();
    expect(first!.dataset.reading).toBeUndefined();
    await act(async () => first!.click());
    const reading = buttons()[0]!;
    expect(label(reading)).toBe("Stop reading");
    // A stop glyph, not the speaker; its row stays shown without the pointer on it (conversation.css).
    expect(reading.dataset.reading).toBe("true");
    expect(reading.querySelector("[data-glyph='stop']")).not.toBeNull();
    const before = cancels;
    await act(async () => reading.click());
    expect(cancels).toBeGreaterThan(before);
    expect(label(buttons()[0])).toBe("Read aloud");
    expect(dom.window.document.querySelector("[data-reading]")).toBeNull();
  });
});

test("Escape stops reading aloud", async () => {
  await withTranscript(async () => {
    await act(async () => buttons()[0]!.click());
    expect(label(buttons()[0])).toBe("Stop reading");
    const before = cancels;
    await act(async () => void escape());
    expect(cancels).toBeGreaterThan(before);
    expect(label(buttons()[0])).toBe("Read aloud");
  });
});

test("reading another answer stops the first", async () => {
  await withTranscript(async () => {
    const [first, second] = buttons();
    await act(async () => first!.click());
    await act(async () => second!.click());
    const [a, b] = buttons();
    expect(label(a)).toBe("Read aloud");
    expect(label(b)).toBe("Stop reading");
    await act(async () => b!.click());
  });
});

test("in the app, the app's voice reads and stops, and the palette's or CLI's stop shows at once", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const actions = {
    "readAloud.speak": async (params: Record<string, unknown>) => void calls.push(["readAloud.speak", params]),
    "readAloud.stop": async (params: Record<string, unknown>) => void calls.push(["readAloud.stop", params]),
  };
  (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions = actions;
  // The app says it reads aloud for this page, nothing yet.
  applyHostEvent({ kind: "readAloud", value: { id: null } });
  const spokenBefore = spoken.length;
  try {
    await withTranscript(async () => {
      await act(async () => buttons()[0]!.click());
      expect(calls).toEqual([
        [
          "readAloud.speak",
          { id: "e1", text: "The hosted test run is still queued behind two other jobs.", lang: "en" },
        ],
      ]);
      // The web view's own voice stays silent: the app speaks.
      expect(spoken.length).toBe(spokenBefore);
      expect(label(buttons()[0])).toBe("Stop reading");

      // Stop Reading Aloud from the palette, the CLI or MCP: the app pushes that nothing reads.
      await act(async () => applyHostEvent({ kind: "readAloud", value: { id: null } }));
      expect(label(buttons()[0])).toBe("Read aloud");

      // Read again, then the second press asks the app to stop.
      await act(async () => buttons()[0]!.click());
      await act(async () => buttons()[0]!.click());
      expect(calls.at(-1)).toEqual(["readAloud.stop", {}]);
      expect(label(buttons()[0])).toBe("Read aloud");

      // Escape asks the app too.
      await act(async () => buttons()[0]!.click());
      await act(async () => void escape());
      expect(calls.at(-1)).toEqual(["readAloud.stop", {}]);
      expect(label(buttons()[0])).toBe("Read aloud");
    });
  } finally {
    delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  }
});
