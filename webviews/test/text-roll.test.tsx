// l10n-allow-file: test fixture labels, not shipped UI.
// One text swap for every live one-line label (ui/motion/TextRoll.tsx; Leo, 2026-11-25, on a subagent
// activity row and the thinking line: "the animation when it changes text at least in teh former is
// still quite jarring bc it doesn't fade at the top/bottom when switching"):
// - every label that changes in place draws through it (or, the Codex-style live line, under its edge
//   and clock), so none keeps a swap of its own;
// - a change rolls the old words out and the new in, through the cell's faded edges;
// - changes while a roll plays coalesce: it lands, then rolls once to the latest words;
// - Reduce Motion crossfades; motion off, or a label out of the transcript's view, swaps at once.
import { afterAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const WEBVIEWS = path.join(import.meta.dir, "..");
const read = (file: string) => readFileSync(path.join(WEBVIEWS, "src", file), "utf8");

describe("every live one-line label rolls on the one text roll", () => {
  // Label, file, what it must draw through.
  const labels: [string, string, RegExp][] = [
    ["a subagent activity row's latest step", "agent-session/acpmux/subagents/AgentLine.tsx", /<Tick\b/],
    ["the hat's status and counts", "agent-session/acpmux/subagents/SubagentTray.tsx", /<Tick\b/],
    ["Working for", "agent-session/acpmux/conversation/WorkingFor.tsx", /<TextRoll\b/],
    ["Tick itself", "agent-session/acpmux/subagents/trayMotion.tsx", /<TextRoll\b/],
  ];
  for (const [label, file, uses] of labels)
    test(`${label} (${file})`, () => {
      const source = read(file);
      expect(source).toMatch(uses);
      expect(source).not.toMatch(/useTextSwap/);
    });

  test("the thinking line rolls under the text roll's edge and clock", () => {
    const source = read("agent-session/acpmux/conversation/Thinking.tsx");
    expect(source).toMatch(/data-text-roll-host=""/);
    expect(source).toMatch(/data-text-roll=\{/);
    const css = read("agent-session/acpmux/conversation/conversation.css");
    expect(css).toMatch(/var\(--ui-text-roll-ms, 180ms\) var\(--ui-text-roll-ease/);
  });

  test("motion.css fades the cell's top and bottom edges while a roll plays", () => {
    const css = read("ui/motion/motion.css");
    expect(css).toMatch(/mask-image: linear-gradient\(\s*to bottom,\s*transparent,\s*#000 var\(--ui-text-roll-edge\)/);
    expect(css).toMatch(/--ui-text-roll-fade: 28%/);
  });
});

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
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const proto = dom.window.HTMLElement.prototype as unknown as Record<string, unknown>;
proto.animate = () => ({ cancel() {} });
let reduce = false;
(dom.window as unknown as { matchMedia: unknown }).matchMedia = (query: string) => ({
  get matches() {
    return query.includes("reduce") && reduce;
  },
  media: query,
  addEventListener() {},
  removeEventListener() {},
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { TextRoll } = await import("../src/ui/motion/TextRoll");

const ended = (node: Element | null) => node?.dispatchEvent(new dom.window.Event("animationend", { bubbles: true }));

async function mount() {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const draw = (text: string) => act(async () => root.render(<TextRoll turn={text}>{text}</TextRoll>));
  const out = () => host.querySelector(".ui-text-roll__out");
  const incoming = () => host.querySelector(".ui-text-roll__in");
  const cell = () => host.querySelector<HTMLElement>(".ui-text-roll")!;
  const land = async () => {
    await act(async () => void ended(out()));
    await act(async () => void ended(incoming()));
  };
  return { host, root, draw, out, incoming, cell, land };
}

describe("TextRoll", () => {
  test("rolls the old words out and the new in, through the faded edge, then settles", async () => {
    const view = await mount();
    await view.draw("Reading the log");
    expect(view.out()).toBeNull();
    await view.draw("Running a command");
    expect(view.out()!.textContent).toBe("Reading the log");
    expect(view.out()!.getAttribute("aria-hidden")).toBe("true");
    expect(view.incoming()!.textContent).toBe("Running a command");
    expect(view.cell().dataset.textRoll).toMatch(/^(odd|even)$/);
    await view.land();
    expect(view.out()).toBeNull();
    expect(view.cell().hasAttribute("data-text-roll")).toBe(false);
    expect(view.host.textContent).toBe("Running a command");
    await act(async () => view.root.unmount());
  });

  test("coalesces: changes during a roll wait for it, then one roll to the latest words", async () => {
    const view = await mount();
    await view.draw("one");
    await view.draw("two");
    await view.draw("three");
    await view.draw("four");
    // The roll in flight plays on with the words it brought.
    expect(view.out()!.textContent).toBe("one");
    expect(view.incoming()!.textContent).toBe("two");
    await view.land();
    // Then one roll, from what showed to the latest; "three" never draws.
    expect(view.out()!.textContent).toBe("two");
    expect(view.incoming()!.textContent).toBe("four");
    await view.land();
    expect(view.host.textContent).toBe("four");
    await act(async () => view.root.unmount());
  });

  test("Reduce Motion crossfades in place", async () => {
    reduce = true;
    const view = await mount();
    await view.draw("Thinking");
    await view.draw("Bash");
    expect(view.cell().hasAttribute("data-text-roll")).toBe(false);
    expect(view.cell().hasAttribute("data-text-roll-fade")).toBe(true);
    expect(view.out()!.textContent).toBe("Thinking");
    await view.land();
    expect(view.host.textContent).toBe("Bash");
    reduce = false;
    await act(async () => view.root.unmount());
  });

  test("motion off swaps at once, and so does a label out of the transcript's view", async () => {
    const view = await mount();
    await view.draw("Thinking");
    dom.window.document.documentElement.dataset.agentMotion = "off";
    await view.draw("Bash");
    expect(view.out()).toBeNull();
    expect(view.host.textContent).toBe("Bash");
    delete dom.window.document.documentElement.dataset.agentMotion;
    await act(async () => view.root.unmount());

    const scroller = dom.window.document.createElement("div");
    scroller.className = "acpmux-scroll";
    dom.window.document.body.append(scroller);
    const host = dom.window.document.createElement("div");
    scroller.append(host);
    const rect = proto.getBoundingClientRect;
    proto.getBoundingClientRect = function (this: HTMLElement) {
      return this === scroller
        ? { top: 0, bottom: 300, left: 0, right: 400, width: 400, height: 300 }
        : { top: 900, bottom: 920, left: 0, right: 100, width: 100, height: 20 };
    };
    const root = createRoot(host);
    await act(async () => root.render(<TextRoll turn="a">a</TextRoll>));
    await act(async () => root.render(<TextRoll turn="b">b</TextRoll>));
    expect(host.querySelector(".ui-text-roll__out")).toBeNull();
    expect(host.textContent).toBe("b");
    proto.getBoundingClientRect = rect;
    await act(async () => root.unmount());
  });
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});
