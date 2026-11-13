// l10n-allow-file: the transcript fixture text is test data, not shipped UI.
// Leo, 2026-11-11 (ask-9d22a47adb): "It's not fast enough and it's not f***ing together enough."
// A send from the latest row lifts its own rows on the send motion's clock (followChase `shift`
// `sent`: the 180 ms `--agent-motion-send` curve the bubble enters on). The send's rise window
// (SEND_RISE_MS, 1 s) still counts later rows as the send's (no cap under the composer), but a row
// that lands after the send motion has played (a delayed thinking or tool row, 400 ms on) arrives on
// the arrival step: passing `sent` there started the 180 ms send curve over after the bubble rested.
import { afterAll, expect, mock, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { installJsdomScroller } from "./support/jsdomScroller";
import { settleReact } from "./support/domTeardown";

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
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
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
  // The send's rise and the arrival step are the chase's, which the blocks follow arm plays; the slim
  // `send` arm (the product's) moves every pass's rows at once and plays neither (VirtualTranscript
  // `slimFollow`; Leo, 2026-11-09: "the scroll up is extremely sluggish").
  cmuxExperiments: { "follow-motion": "blocks" },
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);

// The test's clock: performance.now runs on, plus what the test steps it by.
const realNow = performance.now.bind(performance);
const ownNow = Object.getOwnPropertyDescriptor(performance, "now");
let stepped = 0;
Object.defineProperty(performance, "now", { configurable: true, writable: true, value: () => realNow() + stepped });

// Every chase's `shift` call, with its `sent` argument; the real chase runs as before.
const shifts: { sent: boolean | undefined }[] = [];
const FOLLOW_CHASE = "../src/agent-session/acpmux/conversation/followChase";
// Copied out first: the module's namespace is live, and the mock replaces its bindings.
const realChase = { ...(await import(FOLLOW_CHASE)) };
const realCreate =
  realChase.createFollowChase as typeof import("../src/agent-session/acpmux/conversation/followChase").createFollowChase;
await mock.module(FOLLOW_CHASE, () => ({
  ...realChase,
  createFollowChase: (...args: Parameters<typeof realCreate>) => {
    const chase = realCreate(...args);
    const shift = chase.shift.bind(chase);
    chase.shift = (...shiftArgs: Parameters<typeof shift>) => {
      shifts.push({ sent: shiftArgs[5] });
      return shift(...shiftArgs);
    };
    return chase;
  },
}));

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await settleReact();
  if (ownNow) Object.defineProperty(performance, "now", ownNow);
  else delete (performance as unknown as Record<string, unknown>).now;
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const history = Array.from({ length: 20 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 } as AcpmuxRow,
]).flat();
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

test("a row landing after the send motion played arrives on the arrival step, not the send's clock", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (rows: AcpmuxRow[], sends: number) =>
    act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          sessionId="session-1"
          sends={sends}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      );
      await nextFrame();
    });
  try {
    await render(history, 0);
    await render(
      history.map((item) => ({ ...item })),
      0,
    );
    // Past any settle of the open (a resize's motion step).
    stepped += 1_000;
    await render(
      history.map((item) => ({ ...item })),
      0,
    );

    // The reader sends from the latest row: the prompt's row lands with the send.
    const prompt = row("t20-user", "user", "A new question");
    const sent = [...history, prompt];
    await render(sent, 1);
    // The reply's first row lands right away, inside the send motion.
    const first = shifts.length;
    const thinking = row("t20-thinking", "thinking", "Thinking about it");
    await render([...sent, thinking], 1);
    const early = shifts.slice(first);
    expect(early.length).toBeGreaterThan(0);
    expect(early.every((call) => call.sent === true)).toBe(true);

    // 400 ms on, past the send motion's 180 ms but inside the send's 1 s rise window: a tool row.
    stepped += 400;
    const late = shifts.length;
    await render([...sent, thinking, row("t20-tool", "toolCall", "Read file")], 1);
    const lateShifts = shifts.slice(late);
    expect(lateShifts.length).toBeGreaterThan(0);
    expect(lateShifts.map((call) => call.sent)).toEqual(lateShifts.map(() => false));
  } finally {
    await act(async () => root.unmount());
  }
});

test("a send that makes a tail that fit overflow rises on the send's clock", async () => {
  const container = dom.window.document.createElement("div");
  dom.window.document.body.append(container);
  const root = createRoot(container);
  const render = (rows: AcpmuxRow[], sends: number) =>
    act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          sessionId="session-2"
          sends={sends}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      );
      await nextFrame();
    });
  try {
    // One short turn: the tail fits the viewport, so the chat has not opened at its latest row yet.
    const short = history.slice(0, 3).map((item) => ({ ...item, id: `fit-${item.id}` }));
    await render(short, 0);
    stepped += 1_000;
    await render(
      short.map((item) => ({ ...item })),
      0,
    );
    // The reader sends a long prompt: the tail overflows with the send, and its rise is the send's.
    const long = Array.from({ length: 40 }, (_, index) => `Paragraph ${index} of a long prompt.`).join("\n\n");
    const first = shifts.length;
    await render([...short, row("fit-sent", "user", long)], 1);
    const rise = shifts.slice(first);
    expect(rise.length).toBeGreaterThan(0);
    expect(rise[0]?.sent).toBe(true);
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
});

// Vehicle only (never merges): this line changes nothing.
