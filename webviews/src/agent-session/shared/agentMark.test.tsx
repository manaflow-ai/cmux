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
const { AGENT_MARKS, AgentMark, agentKey, nearBlackOrWhite } = await import("./AgentMark");

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

test("a mark its vendor allows only in black or white draws only on a near-black or near-white text color", async () => {
  expect(nearBlackOrWhite("#ffffff")).toBe(true);
  expect(nearBlackOrWhite("rgba(0, 0, 0, 1)")).toBe(true);
  expect(nearBlackOrWhite("rgba(205, 214, 244, 1)")).toBe(false);
  expect(nearBlackOrWhite("not a color")).toBe(false);
  const doc = dom.window.document;
  const root = createRoot(doc.getElementById("root")!);
  AGENT_MARKS.mono = { viewBox: "0 0 24 24", paths: ["M0 0h24v24H0z"], recolor: "black-white", source: "test" };
  try {
    doc.documentElement.style.setProperty("--agent-text", "rgba(205, 214, 244, 1)");
    await act(async () => root.render(createElement(AgentMark, { agent: "mono" })));
    expect(doc.querySelector("svg")!.classList.contains("agent-mark-generic")).toBe(true);
    // A theme switch to near-white text redraws the mark.
    await act(async () => {
      doc.documentElement.style.setProperty("--agent-text", "rgba(250, 250, 250, 1)");
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(doc.querySelector("svg")!.getAttribute("data-agent")).toBe("mono");
  } finally {
    delete AGENT_MARKS.mono;
    doc.documentElement.style.removeProperty("--agent-text");
    await act(async () => root.unmount());
  }
});
