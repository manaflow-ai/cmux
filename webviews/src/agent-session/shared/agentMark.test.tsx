import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "MutationObserver", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [
    key,
    globals[key],
  ]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AGENT_MARKS, AgentMark, agentKey } = await import("./AgentMark");
const { applyAgentTheme } = await import("./theme");
const { agentPaneTheme, ghosttyDefault } = await import("../../../scripts/agent-pane/theme.mjs");

test("a harness id names its agent by its first word, so variants share a mark", () => {
  expect(agentKey("claude")).toBe("claude");
  expect(agentKey("claude-sr")).toBe("claude");
  expect(agentKey("Gemini_CLI")).toBe("gemini");
  expect(agentKey("")).toBeUndefined();
  expect(agentKey(undefined)).toBeUndefined();
});

test("an agent with a mark draws it in currentColor; any other agent draws the generic glyph", async () => {
  const doc = dom.window.document;
  const root = createRoot(doc.getElementById("root")!);
  AGENT_MARKS.test = { viewBox: "0 0 24 24", paths: ["M0 0h24v24H0z"], source: "test" };
  try {
    await act(async () => root.render(createElement(AgentMark, { agent: "test-variant", size: 18, label: "Test" })));
    const svg = doc.querySelector("svg")!;
    expect(svg.getAttribute("data-agent")).toBe("test");
    expect(svg.getAttribute("fill")).toBe("currentColor");
    expect(svg.getAttribute("width")).toBe("18");
    expect(svg.getAttribute("role")).toBe("img");
    expect(svg.getAttribute("aria-label")).toBe("Test");
    await act(async () => root.render(createElement(AgentMark, { agent: "unknown-agent" })));
    const generic = doc.querySelector("svg")!;
    expect(generic.classList.contains("agent-mark-generic")).toBe(true);
    expect(generic.getAttribute("aria-hidden")).toBe("true");
    expect(generic.getAttribute("role")).toBeNull();
  } finally {
    delete AGENT_MARKS.test;
    await act(async () => root.unmount());
  }
});

// Catppuccin's Ghostty themes, as the terminal hands them to the pane.
const catppuccin = (background: number, foreground: number, palette: number[]) => {
  const rgb = (hex: number) => ({ r: hex >> 16, g: (hex >> 8) & 0xff, b: hex & 0xff, a: 1 });
  return agentPaneTheme({
    ...ghosttyDefault,
    background: rgb(background),
    foreground: rgb(foreground),
    palette: palette.map(rgb),
  });
};
// prettier-ignore
const mocha = catppuccin(0x1e1e2e, 0xcdd6f4, [0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de, 0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8]);
// prettier-ignore
const latte = catppuccin(0xeff1f5, 0x4c4f69, [0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xacb0be, 0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xbcc0cc]);

test("a black-or-white-only mark draws pure white on Mocha and pure black on Latte; a tinted mark keeps currentColor", async () => {
  const doc = dom.window.document;
  const root = createRoot(doc.getElementById("root")!);
  const fills = () => [...doc.querySelectorAll("svg")].map((svg) => svg.getAttribute("fill"));
  try {
    applyAgentTheme(mocha);
    const marks = createElement(
      "div",
      null,
      createElement(AgentMark, { agent: "codex" }),
      createElement(AgentMark, { agent: "claude" }),
    );
    await act(async () => root.render(marks));
    expect(fills()).toEqual(["#fff", "currentColor"]);
    // A live theme switch redraws the mark.
    await act(async () => {
      applyAgentTheme(latte);
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(fills()).toEqual(["#000", "currentColor"]);
  } finally {
    delete doc.documentElement.dataset.theme;
    await act(async () => root.unmount());
  }
});

test("every registered mark names its source in AGENT_MARKS.md", async () => {
  const attributions = await Bun.file(new URL("./AGENT_MARKS.md", import.meta.url)).text();
  for (const [key, spec] of Object.entries(AGENT_MARKS)) {
    expect(attributions).toContain(`\`${key}\``);
    expect(attributions).toContain(`\`${spec.source}\``);
  }
  expect(Object.keys(AGENT_MARKS).sort()).toEqual(["amp", "claude", "codex", "cursor", "gemini", "openai", "opencode"]);
  expect(AGENT_MARKS.codex!.recolor).toBe("black-white");
});

test("a two-tone mark draws its second tone lighter", async () => {
  const doc = dom.window.document;
  const root = createRoot(doc.getElementById("root")!);
  try {
    await act(async () => root.render(createElement(AgentMark, { agent: "opencode" })));
    const paths = [...doc.querySelectorAll("svg path")];
    expect(paths.map((path) => path.getAttribute("opacity"))).toEqual([null, "0.35"]);
  } finally {
    await act(async () => root.unmount());
  }
});
