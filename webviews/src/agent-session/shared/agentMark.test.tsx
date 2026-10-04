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
const { AgentMark, agentMarkObserving, setAgentMarkStyle } = await import("./AgentMark");
const { agentKey } = await import("./agentKey");
const { agentBrand, AGENT_BRAND_RESOLUTION_CASES, SUPPORTED_AGENTS } = await import("./agentBrand");
const { agentDisplayName } = await import("../acpmux/agents");
const { applyAgentTheme } = await import("./theme");
const { agentPaneTheme, ghosttyDefault } = await import("../../../scripts/agent-pane/theme.mjs");

test("a harness id names its agent by its first word, so variants share a mark", () => {
  expect(agentKey("claude")).toBe("claude");
  expect(agentKey("claude-sr")).toBe("claude");
  expect(agentKey("Gemini_CLI")).toBe("gemini");
  expect(agentKey("")).toBeUndefined();
  expect(agentKey(undefined)).toBeUndefined();
});

test("an agent with a mark draws its brand's paths; any other agent draws the generic glyph", async () => {
  const root = createRoot(doc.getElementById("root")!);
  try {
    await act(async () => root.render(createElement(AgentMark, { agent: "claude-sr", size: 18, label: "Claude" })));
    const svg = doc.querySelector("svg")!;
    expect(svg.getAttribute("data-agent")).toBe("claude");
    expect(svg.getAttribute("fill")).toBe("#D97757");
    expect(svg.getAttribute("width")).toBe("18");
    expect(svg.getAttribute("role")).toBe("img");
    expect(svg.getAttribute("aria-label")).toBe("Claude");
    await act(async () => root.render(createElement(AgentMark, { agent: "unknown-agent" })));
    const generic = doc.querySelector("svg")!;
    expect(generic.classList.contains("agent-mark-generic")).toBe(true);
    expect(generic.getAttribute("aria-hidden")).toBe("true");
    expect(generic.getAttribute("role")).toBeNull();
  } finally {
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

const doc = dom.window.document;
const fills = () =>
  [...doc.querySelectorAll("svg.agent-mark")].map((svg) => [svg.getAttribute("data-agent"), svg.getAttribute("fill")]);
async function renderMarks(agents: string[], props: Record<string, unknown> = {}) {
  const root = createRoot(doc.getElementById("root")!);
  await act(async () =>
    root.render(
      createElement("div", null, ...agents.map((agent) => createElement(AgentMark, { key: agent, agent, ...props }))),
    ),
  );
  return root;
}
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("marks fill in their vendor's colors by default, per theme lightness: Mocha, then Latte", async () => {
  applyAgentTheme(mocha);
  const root = await renderMarks(["claude", "codex", "cursor", "amp"]);
  try {
    expect(fills()).toEqual([
      ["claude", "#D97757"],
      ["openai", "#FFFFFF"],
      ["cursor", "#EDECEC"],
      ["amp", "#FFFFFF"],
    ]);
    // A live theme switch recolors the marks.
    await act(async () => {
      applyAgentTheme(latte);
      await settle();
    });
    expect(fills()).toEqual([
      ["claude", "#D97757"],
      ["openai", "#000000"],
      ["cursor", "#26251E"],
      ["amp", "#000000"],
    ]);
  } finally {
    delete doc.documentElement.dataset.theme;
    await act(async () => root.unmount());
  }
});

test("the mono style fills every mark white on Mocha and black on Latte", async () => {
  applyAgentTheme(mocha);
  const root = await renderMarks(["claude", "codex", "gemini"]);
  try {
    await act(async () => {
      setAgentMarkStyle("mono");
      await settle();
    });
    expect(fills().map(([, fill]) => fill)).toEqual(["#fff", "#fff", "#fff"]);
    // Gemini's color highlights are brand-only.
    expect(doc.querySelector("linearGradient")).toBeNull();
    await act(async () => {
      applyAgentTheme(latte);
      await settle();
    });
    expect(fills().map(([, fill]) => fill)).toEqual(["#000", "#000", "#000"]);
    await act(async () => {
      setAgentMarkStyle("brand");
      await settle();
    });
    expect(fills().map(([, fill]) => fill)).toEqual(["#D97757", "#000000", "#3186FF"]);
    expect(doc.querySelectorAll("linearGradient").length).toBe(3);
    // onDark wins over the theme in mono too.
    await act(async () => root.render(createElement(AgentMark, { agent: "codex", onDark: true })));
    await act(async () => {
      setAgentMarkStyle("mono");
      await settle();
    });
    expect(fills()).toEqual([["openai", "#fff"]]);
  } finally {
    setAgentMarkStyle("brand");
    delete doc.documentElement.dataset.theme;
    await act(async () => root.unmount());
  }
});

test("before any theme arrives marks assume the dark default; onDark overrides it for an inverted surface", async () => {
  const root = await renderMarks(["codex"]);
  try {
    expect(fills()).toEqual([["openai", "#FFFFFF"]]);
    await act(async () => root.render(createElement(AgentMark, { agent: "codex", onDark: false })));
    expect(fills()).toEqual([["openai", "#000000"]]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("each Gemini mark's highlights point at its own gradients", async () => {
  const root = await renderMarks(["gemini"]);
  try {
    await act(async () =>
      root.render(
        createElement(
          "div",
          null,
          createElement(AgentMark, { agent: "gemini" }),
          createElement(AgentMark, { agent: "gemini" }),
        ),
      ),
    );
    const ids = [...doc.querySelectorAll("linearGradient")].map((gradient) => gradient.id);
    expect(ids.length).toBe(6);
    expect(new Set(ids).size).toBe(6);
    const refs = [...doc.querySelectorAll("path[fill^='url(']")].map(
      (path) => /^url\(#(.+)\)$/.exec(path.getAttribute("fill")!)![1]!,
    );
    expect(refs.length).toBeGreaterThan(0);
    for (const id of refs) expect(doc.getElementById(id)?.tagName).toBe("linearGradient");
  } finally {
    await act(async () => root.unmount());
  }
});

test("a two-tone mark keeps both tones in brand color and lightens the inner one in mono", async () => {
  applyAgentTheme(latte);
  const root = await renderMarks(["opencode"]);
  const paths = () =>
    [...doc.querySelectorAll("svg path")].map((path) => [path.getAttribute("fill"), path.getAttribute("opacity")]);
  try {
    expect(fills()).toEqual([["opencode", "#211E1E"]]);
    expect(paths()).toEqual([
      [null, null],
      ["#CFCECD", null],
    ]);
    await act(async () => {
      applyAgentTheme(mocha);
      await settle();
    });
    expect(fills()).toEqual([["opencode", "#F1ECEC"]]);
    expect(paths()).toEqual([
      [null, null],
      ["#4B4646", null],
    ]);
    await act(async () => {
      setAgentMarkStyle("mono");
      await settle();
    });
    expect(paths()).toEqual([
      [null, null],
      [null, "0.35"],
    ]);
  } finally {
    setAgentMarkStyle("brand");
    delete doc.documentElement.dataset.theme;
    await act(async () => root.unmount());
  }
});

test("an id that names an Object prototype key draws the generic glyph and a title-cased name", async () => {
  const root = await renderMarks(["constructor-dev"]);
  try {
    expect(doc.querySelector("svg")!.classList.contains("agent-mark-generic")).toBe(true);
    expect(agentDisplayName("constructor-dev")).toBe("Constructor Dev");
  } finally {
    await act(async () => root.unmount());
  }
});

test("the shared root observer detaches when the last mark unmounts and returns with the next", async () => {
  const root = await renderMarks(["claude", "codex"]);
  expect(agentMarkObserving()).toBe(true);
  await act(async () => root.unmount());
  expect(agentMarkObserving()).toBe(false);
  const again = await renderMarks(["claude"]);
  expect(agentMarkObserving()).toBe(true);
  await act(async () => again.unmount());
});

test("agent strings resolve to the same brands as the Swift catalog", () => {
  for (const [input, brand] of AGENT_BRAND_RESOLUTION_CASES)
    expect([input, agentBrand(input) ?? null]).toEqual([input, brand]);
});

test("every supported agent with a brand draws that brand's mark, the rest the generic glyph", async () => {
  // R79: these must all have real marks.
  for (const agent of ["claude", "codex", "chatgpt", "opencode", "pi", "hermes-agent", "dsh", "deepseek"])
    expect([agent, agentBrand(agent) !== undefined]).toEqual([agent, true]);
  const root = await renderMarks(SUPPORTED_AGENTS.map((agent) => agent.id));
  try {
    const drawn = [...doc.querySelectorAll("#root svg")].map((svg) => svg.getAttribute("data-agent"));
    expect(drawn).toEqual(SUPPORTED_AGENTS.map((agent) => agent.brand));
  } finally {
    await act(async () => root.unmount());
  }
});

test("a tiled mark draws its tile in brand color only, and mono hides brand-only detail", async () => {
  applyAgentTheme(mocha);
  const root = await renderMarks(["kiro"]);
  const svg = () => doc.querySelector("svg.agent-mark")!;
  try {
    expect(svg().querySelector("rect")?.getAttribute("fill")).toBe("#9046FF");
    expect(svg().getAttribute("viewBox")).toBe("0 0 1200 1200");
    expect(svg().querySelectorAll("path").length).toBe(2);
    await act(async () => {
      setAgentMarkStyle("mono");
      await settle();
    });
    expect(svg().querySelector("rect")).toBeNull();
    // The eyes are cut out of the ghost in mono; their brand-only path is not drawn.
    expect(svg().querySelectorAll("path").length).toBe(1);
  } finally {
    setAgentMarkStyle("brand");
    delete doc.documentElement.dataset.theme;
    await act(async () => root.unmount());
  }
});
