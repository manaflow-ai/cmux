// l10n-allow-file: test fixture subagent tasks and commands, not shipped UI.
// The composer hat keeps what ended and moves its lines in and out (Leo, 2026-11-07: "they, like,
// disappear instantly. So, like, if you have it expanded, then it just, like, it disappears, which is,
// like, bad ... the things coming, they shouldn't just, like, pop in, burst in, like, appear
// instantly, and, like, disappear instantly"):
// - a finished command is a done line with its time, a failed one says failed, and neither has Stop;
// - the hat says when it is held (open, or the pointer on it), so App.tsx's linger expires nothing then;
// - in the open hat a line that leaves keeps its node (`data-leaving`) and folds its height to 0 on
//   the shared fold, unmounting when that ends; a line that joins grows from 0; with no motion both
//   apply at once.
import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

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
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => "visible" });
(dom.window as unknown as { matchMedia: unknown }).matchMedia = (query: string) => ({
  matches: false,
  media: query,
  addEventListener: () => {},
  removeEventListener: () => {},
});

/// The Web Animations the tray started, each with its keyframes; a test ends them.
type Played = { node: Element; frames: Keyframe[]; onfinish: (() => void) | null; oncancel: (() => void) | null };
let played: Played[] = [];
const proto = dom.window.HTMLElement.prototype as unknown as Record<string, unknown>;
const motion = (on: boolean) => {
  if (on)
    proto.animate = function (this: Element, frames: Keyframe[]) {
      const animation: Played & { cancel(): void } = {
        node: this,
        frames,
        onfinish: null,
        oncancel: null,
        cancel() {
          this.oncancel?.();
        },
      };
      played.push(animation);
      return animation;
    };
  else delete proto.animate;
};

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { SubagentTray } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const { rememberTrayOpen, resetTrayOpenMemory } = await import("../src/agent-session/acpmux/subagents/trayFoldMemory");
const { useTrayLinger } = await import("../src/agent-session/acpmux/subagents/trayLinger");
const { ComposerHatLingerStage } = await import("../src/gallery/fixtures/ComposerHatLingerStage");
type TrayItem = import("../src/agent-session/acpmux/subagents/runningTray").TrayItem;
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});
setPaneLanguage("en");
beforeEach(() => {
  played = [];
  resetTrayOpenMemory();
});

const now = Date.now();
const agentItem = (agent: Partial<Subagent> & { id: string; task: string }): TrayItem => ({
  kind: "agent",
  id: agent.id,
  agent: { parent: null, name: agent.id, state: "running", startedAt: now - 9_000, ...agent },
  depth: 0,
});
const commandItem = (id: string, state: "running" | "completed" | "failed", endedAt?: number): TrayItem => ({
  kind: "command",
  id,
  command: {
    id,
    command: `bun test ${id}`,
    description: `Run the ${id} tests`,
    state,
    toolCallId: id,
    processId: `chat/${id}`,
    startedAt: now - 75_000,
    ...(endedAt === undefined ? {} : { endedAt }),
  },
});
/// Two frames: the page's reveal gate opens after its first frames.
const frames = async () => {
  for (let index = 0; index < 3; index++)
    await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
};

function mount(chat: string) {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const holds: boolean[] = [];
  const draw = (items: TrayItem[], finished: TrayItem[] = []) =>
    act(async () =>
      root.render(
        createElement(SubagentTray, {
          chat,
          items,
          finished,
          working: true,
          waiting: new Set<string>(),
          onOpen: () => {},
          stopProcess: async () => {},
          onHold: (held: boolean) => holds.push(held),
        }),
      ),
    );
  return {
    host,
    holds,
    draw,
    rows: () => [...host.querySelectorAll<HTMLLIElement>(".acpmux-running-tray__list > li")],
    done: async () => act(async () => root.unmount()),
  };
}

describe("composer hat: finished lines", () => {
  test("a finished command is a done line with its time; a failed one says failed; neither stops", async () => {
    motion(false);
    rememberTrayOpen("chat-done", true);
    const view = mount("chat-done");
    try {
      await view.draw([], [commandItem("ok", "completed", now - 15_000), commandItem("bad", "failed", now - 5_000)]);
      const lines = [...view.host.querySelectorAll<HTMLElement>(".acpmux-agent-line")];
      expect(lines.map((line) => line.getAttribute("data-status"))).toEqual(["done", "failed"]);
      // Ran 60 s and 70 s.
      expect(lines[0]!.textContent).toContain("1m");
      expect(lines[1]!.textContent).toContain("Failed");
      expect(view.host.querySelectorAll("button[aria-label='Stop only this command']").length).toBe(0);
    } finally {
      await view.done();
    }
  });

  test("the hat says it is held while open or under the pointer, and lets go when it is neither", async () => {
    motion(false);
    const view = mount("chat-hold");
    try {
      await view.draw([commandItem("c1", "running")]);
      expect(view.holds.at(-1) ?? false).toBe(false);
      const head = view.host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!;
      await act(async () => head.click());
      expect(view.holds.at(-1)).toBe(true);
      await act(async () => head.click());
      expect(view.holds.at(-1)).toBe(false);
      const tray = view.host.querySelector(".acpmux-running-tray")!;
      await act(async () => {
        tray.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true }));
      });
      expect(view.holds.at(-1)).toBe(true);
      await act(async () => {
        tray.dispatchEvent(new dom.window.MouseEvent("pointerout", { bubbles: true }));
      });
      expect(view.holds.at(-1)).toBe(false);
    } finally {
      await view.done();
    }
    expect(view.holds.at(-1)).toBe(false);
  });
});

describe("composer hat: lines enter and leave", () => {
  test("a leaving line keeps its node while its height folds to 0, then goes", async () => {
    motion(true);
    rememberTrayOpen("chat-leave", true);
    const view = mount("chat-leave");
    try {
      const a = agentItem({ id: "a1", task: "Diagnose nightly lag" });
      const b = agentItem({ id: "a2", task: "Watch the build", startedAt: now - 1_000 });
      await view.draw([a, b]);
      await frames();
      expect(view.rows().length).toBe(2);
      played = [];
      await view.draw([a]);
      const rows = view.rows();
      expect(rows.length).toBe(2);
      const leaving = rows.find((row) => row.hasAttribute("data-leaving"));
      expect(leaving?.textContent).toContain("Watch the build");
      expect(leaving?.hasAttribute("inert")).toBe(true);
      const fold = played.find((animation) => leaving!.contains(animation.node));
      expect(fold).toBeDefined();
      expect(fold!.frames.at(-1)).toMatchObject({ height: "0px", opacity: 0 });
      await act(async () => fold!.onfinish?.());
      expect(view.rows().length).toBe(1);
      expect(view.rows()[0]!.textContent).toContain("Diagnose nightly lag");
    } finally {
      await view.done();
    }
  });

  test("a joining line grows from 0 height in the open hat", async () => {
    motion(true);
    rememberTrayOpen("chat-join", true);
    const view = mount("chat-join");
    try {
      const a = agentItem({ id: "a1", task: "Diagnose nightly lag" });
      await view.draw([a]);
      await frames();
      played = [];
      await view.draw([agentItem({ id: "a2", task: "Watch the build", startedAt: now - 1_000 }), a]);
      const joined = view.rows().find((row) => row.textContent?.includes("Watch the build"));
      const grow = played.find((animation) => joined!.contains(animation.node));
      expect(grow).toBeDefined();
      expect(grow!.frames[0]).toMatchObject({ height: "0px", opacity: 0 });
    } finally {
      await view.done();
    }
  });

  test("with no motion a leaving line goes at once", async () => {
    motion(false);
    rememberTrayOpen("chat-still", true);
    const view = mount("chat-still");
    try {
      const a = agentItem({ id: "a1", task: "Diagnose nightly lag" });
      const b = agentItem({ id: "a2", task: "Watch the build", startedAt: now - 1_000 });
      await view.draw([a, b]);
      await view.draw([a]);
      expect(view.rows().length).toBe(1);
    } finally {
      await view.done();
    }
  });
});

describe("composer hat: review follow-ups", () => {
  test("F1: the linger reads the session's clock, so a peer's end stays while the hat is held", async () => {
    // The peer's clock runs 3 minutes behind this computer's (`clockOffsetMs`: this computer minus
    // the session). Its subagent ended just now on its own clock.
    const offset = 180_000;
    const local = 1_000_000_000;
    const ended = [{ key: "agent:peer", endedAt: local - offset }];
    let kept: ReadonlyMap<string, number> = new Map();
    function Probe() {
      kept = useTrayLinger("chat-peer", [], ended, true, { offsetMs: offset, clock: () => local }).kept;
      return null;
    }
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    try {
      await act(async () => root.render(createElement(Probe)));
      expect(kept.has("agent:peer")).toBe(true);
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("F3: the gallery stage stamps a command's end when it finishes, not when the stage mounted", async () => {
    motion(false);
    const realNow = Date.now;
    let clock = realNow();
    Date.now = () => clock;
    const host = dom.window.document.getElementById("root")!;
    const root = createRoot(host);
    try {
      await act(async () => root.render(createElement(ComposerHatLingerStage, { grace: 600_000 })));
      // Five minutes after the stage mounted, the command finishes: it ran 64 s before mount plus 5 m.
      clock += 300_000;
      await act(async () => host.querySelector<HTMLButtonElement>('[data-stage="finish"]')!.click());
      const head = host.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!;
      await act(async () => head.click());
      const done = host.querySelector<HTMLElement>('.acpmux-agent-line[data-status="done"]');
      expect(done).not.toBeNull();
      expect(done!.textContent).toContain("6m 4s");
    } finally {
      await act(async () => root.unmount());
      Date.now = realNow;
    }
  });
});
