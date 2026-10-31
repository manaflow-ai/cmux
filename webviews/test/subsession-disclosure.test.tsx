// The transcript's sub-session rows are one-line disclosures: the prompt opens as Markdown below
// the anchored line, while adjacent starts collapse into one group row.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { setPaneLanguage } from "../src/agent-session/acpmux/i18n";
import {
  FindReveal,
  findMatchesIncremental,
  paintFindHighlights,
} from "../src/agent-session/acpmux/conversation/chatFind";
import { SubsessionCallCard } from "../src/agent-session/acpmux/conversation/SubsessionCallCard";
import { SubsessionContext, SubsessionStore } from "../src/agent-session/acpmux/subagents/subsessions";
import {
  resetTranscriptDisclosure,
  TranscriptDisclosureProvider,
} from "../src/agent-session/acpmux/conversation/transcriptDisclosure";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { SubsessionCall } from "../src/agent-session/acpmux/conversation/subsessionCalls";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

const start = (name: string, sessionId = `${name}-id`): Extract<SubsessionCall, { tool: "start" }> => ({
  tool: "start",
  running: false,
  sessionId,
  name,
  prompt: `# ${name}\n\nRun the **full** review and report the result.`,
  harness: "claude",
  model: "opus",
});

const tool = (name: string) =>
  ({
    id: `${name}-call`,
    title: "mcp__cmux-subsessions__start_session",
    status: "completed",
    inputSummary: JSON.stringify({ name, prompt: start(name).prompt }),
    output: `Started sub-session ${name} (sessionId ${name}-id, depth 1).`,
  }) as never;

function installDom() {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    NodeFilter: dom.window.NodeFilter,
    CSS: { highlights: new Map() },
    Highlight: class {
      constructor(...ranges: Range[]) {
        Object.assign(this, { ranges });
      }
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTranscriptDisclosure();
  setPaneLanguage("en");
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

test("a collapsed sub-session is one disclosure row and expansion renders the full Markdown prompt", async () => {
  const container = installDom();
  const scroll = container.ownerDocument.createElement("div");
  scroll.style.overflowY = "auto";
  const mount = container.ownerDocument.createElement("div");
  scroll.append(mount);
  container.append(scroll);
  root = createRoot(mount);
  await act(async () => root!.render(<SubsessionCallCard call={start("msg-fold")} tool={tool("msg-fold")} />));
  const row = container.querySelector<HTMLElement>(".cv-disclosure")!;
  expect(row.querySelectorAll(".cv-disclosure__line")).toHaveLength(1);
  expect(row.textContent).not.toContain("Run the full review");
  scroll.scrollTop = 37;
  const before = scroll.scrollTop;
  await act(async () => row.querySelector<HTMLButtonElement>(".cv-disclosure__toggle")!.click());
  expect(scroll.scrollTop).toBe(before);
  expect(row.textContent).toContain("full review");
  expect(row.querySelector(".cv-disclosure__label")?.textContent).toContain("msg-fold");
});

test("three adjacent starts render as one collapsed group row", () => {
  const html = renderToStaticMarkup(
    <SubsessionCallCard
      group={[
        { call: start("msg-fold"), tool: tool("msg-fold") },
        { call: start("picker-polish"), tool: tool("picker-polish") },
        { call: start("cloud-demo"), tool: tool("cloud-demo") },
      ]}
    />,
  );
  expect((html.match(/class="cv-disclosure"/g) ?? []).length).toBe(1);
  expect(html).toContain("Started 3 sub-sessions: msg-fold, picker-polish, cloud-demo");
});

test("collapsed groups follow child sessions after their start calls finish", async () => {
  const container = installDom();
  const store = new SubsessionStore();
  const names = ["msg-fold", "picker-polish", "cloud-demo"];
  const entries = names.map((name) => ({ call: start(name), tool: tool(name) }));
  const setChild = (change: Partial<AcpmuxSessionEntry>) =>
    store.set(
      names.map(
        (name, index) =>
          ({
            sessionId: `${name}-id`,
            startedBy: "parent",
            status: "idle",
            lane: "idle",
            ...(index === 0 ? change : {}),
          }) as AcpmuxSessionEntry,
      ),
    );
  setChild({ lane: "working" });
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => {} }}>
        <SubsessionCallCard group={entries} />
      </SubsessionContext.Provider>,
    ),
  );
  const status = () => container.querySelector(".cv-disclosure__status")!;
  expect(status().textContent).toContain("Working");
  expect(status().querySelector("svg")).not.toBeNull();
  await act(async () => setChild({ lane: "input" }));
  expect(status().textContent).toContain("1 waiting");
  expect(status().querySelector("svg")).toBeNull();
  await act(async () => setChild({ lane: "failed" }));
  expect(status().textContent).toContain("1 failed");
  await act(async () => setChild({ lane: "failed", retry: { attempt: 1, of: 4 } }));
  expect(status().textContent).toContain("Working");
  expect(status().textContent).not.toContain("failed");
  expect(status().querySelector("svg")).not.toBeNull();
  await act(async () => setChild({ lane: "working", waitsForSlot: true }));
  expect(status().textContent).toContain("1 waiting");
  await act(async () => setChild({ lane: "idle" }));
  expect(status().textContent).toBe("Done");
  expect(status().querySelector("svg")).toBeNull();
});

test("single and grouped disclosures keep independent choices across virtualized remounts", async () => {
  const container = installDom();
  root = createRoot(container);
  const entries = ["msg-fold", "picker-polish", "cloud-demo"].map((name) => ({ call: start(name), tool: tool(name) }));
  const render = async (sessionId = "parent") =>
    act(async () =>
      root!.render(
        <TranscriptDisclosureProvider sessionId={sessionId}>
          <SubsessionCallCard call={start("single")} tool={tool("single")} />
          <SubsessionCallCard call={start("other")} tool={tool("other")} />
          <SubsessionCallCard group={entries} />
        </TranscriptDisclosureProvider>,
      ),
    );
  const toggles = () => [...container.querySelectorAll<HTMLButtonElement>(".cv-disclosure__toggle")];
  await render();
  await act(async () => toggles()[0]!.click());
  await act(async () => toggles()[2]!.click());
  await act(async () => toggles()[3]!.click());
  expect(toggles().map((button) => button.getAttribute("aria-expanded"))).toEqual([
    "true",
    "false",
    "true",
    "true",
    "false",
    "false",
  ]);
  await act(async () => root!.unmount());
  root = createRoot(container);
  await render();
  expect(toggles().map((button) => button.getAttribute("aria-expanded"))).toEqual([
    "true",
    "false",
    "true",
    "true",
    "false",
    "false",
  ]);
  expect(container.querySelector(".cv-subsession__markdown strong")?.textContent).toBe("full");
  await act(async () => root!.render(null));
  await render("different-parent");
  expect(toggles().map((button) => button.getAttribute("aria-expanded"))).toEqual(["false", "false", "false"]);
});

test("a result's Show more choice survives closing its card and virtualized remounts", async () => {
  const container = installDom();
  Object.defineProperty(dom!.window.HTMLElement.prototype, "scrollHeight", { configurable: true, get: () => 200 });
  Object.defineProperty(dom!.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 60 });
  const call: SubsessionCall = {
    tool: "wait",
    running: false,
    timedOut: false,
    sessions: ["review", "lint"].map((name) => ({
      sessionId: name,
      name,
      state: "done",
      reply: "First paragraph.\n\nSecond paragraph.\n\nLast paragraph.",
    })),
  };
  root = createRoot(container);
  const render = (sessionId = "parent") =>
    act(async () =>
      root!.render(
        <TranscriptDisclosureProvider sessionId={sessionId}>
          <SubsessionCallCard call={call} tool={tool("wait")} />
        </TranscriptDisclosureProvider>,
      ),
    );
  const cards = () => [...container.querySelectorAll<HTMLElement>(".cv-disclosure")];
  const toggle = (index: number) => cards()[index]!.querySelector<HTMLButtonElement>(".cv-disclosure__toggle")!;
  const more = (index: number) => cards()[index]!.querySelector<HTMLButtonElement>(".cv-subsession__cut button")!;
  await render();
  await act(async () => toggle(0).click());
  await act(async () => toggle(1).click());
  await act(async () => more(0).click());
  expect(more(0).getAttribute("aria-expanded")).toBe("true");
  expect(more(1).getAttribute("aria-expanded")).toBe("false");
  await act(async () => toggle(0).click());
  await act(async () => toggle(0).click());
  expect(more(0).getAttribute("aria-expanded")).toBe("true");
  await act(async () => root!.unmount());
  root = createRoot(container);
  await render();
  expect(more(0).getAttribute("aria-expanded")).toBe("true");
  expect(more(1).getAttribute("aria-expanded")).toBe("false");
  expect(cards()[0]!.querySelector(".cv-subsession__markdown")!.hasAttribute("data-cut")).toBe(false);
  await render("different-parent");
  await act(async () => toggle(0).click());
  expect(more(0).getAttribute("aria-expanded")).toBe("false");
});

test("a started sub-session's row is its name, with no narration in front of it, in every language", async () => {
  // Transcript audit (cmuxterm-hq#5154): the harness mark names the type; "Started sub-session" was narration.
  const container = installDom();
  root = createRoot(container);
  for (const language of ["en", "de", "ja", "tr"]) {
    await act(async () => {
      setPaneLanguage(language);
      root!.render(<SubsessionCallCard call={start("tests")} tool={tool("tests")} />);
    });
    expect(container.querySelector(".cv-disclosure__label")?.textContent).toBe("tests");
  }
});

test("Find opens both a group and its matching child's prompt, leaving siblings closed", async () => {
  const container = installDom();
  root = createRoot(container);
  const entries = ["msg-fold", "picker-polish", "cloud-demo"].map((name) => ({ call: start(name), tool: tool(name) }));
  const render = async (needle?: string) =>
    act(async () =>
      root!.render(
        <FindReveal.Provider value={needle ? { rowId: "row", card: false, needle, repaint: () => {} } : undefined}>
          <SubsessionCallCard group={entries} />
        </FindReveal.Provider>,
      ),
    );
  await render();
  expect(container.querySelectorAll(".cv-disclosure__toggle")).toHaveLength(1);
  expect(container.querySelector(".cv-subsession__markdown")).toBeNull();
  await render("# picker-polish");
  const toggles = [...container.querySelectorAll(".cv-disclosure__toggle")];
  expect(toggles.map((button) => button.getAttribute("aria-expanded"))).toEqual(["true", "false", "true", "false"]);
  expect(container.querySelector(".cv-subsession__markdown h1")?.textContent).toBe("picker-polish");
  expect(container.querySelector(".cv-subsession__raw button")?.getAttribute("aria-expanded")).toBe("true");
});

test("Find's two prompt occurrences select the first and second child, never their Raw copies", async () => {
  const container = installDom();
  root = createRoot(container);
  const entries = ["first", "second"].map((name) => ({ call: start(name), tool: tool(name) }));
  const items: AcpmuxActivity[] = entries.map(({ tool }) => ({ kind: "tool", text: "start", tool }));
  const row: AcpmuxRow = { id: "row", kind: "activity", version: 1, at: 1, items };
  const matches = findMatchesIncremental([row], "review").matches;
  expect(matches).toHaveLength(2);
  await act(async () =>
    root!.render(
      <FindReveal.Provider value={{ rowId: "row", card: false, needle: "review", repaint: () => {} }}>
        <div data-row-id="row">
          <SubsessionCallCard group={entries} />
        </div>
      </FindReveal.Provider>,
    ),
  );
  for (const [index, match] of matches.entries()) {
    const range = paintFindHighlights(container, "review", { ...match, card: false });
    const prompt = range?.startContainer.parentElement?.closest(".cv-subsession__markdown");
    expect(prompt).not.toBeNull();
    expect(prompt?.querySelector("h1")?.textContent).toBe(entries[index]!.call.name);
    const highlights = (scope.CSS as { highlights: Map<string, { ranges: Range[] }> }).highlights;
    expect(highlights.get("acpmux-find")!.ranges).toHaveLength(1);
  }
  // Raw remains available, including its exact request text; it simply isn't a second search hit.
  expect(container.querySelectorAll(".cv-mcp-call")).toHaveLength(2);
});

test("Find retains Raw-only fields and response matches alongside the displayed prompt", async () => {
  const container = installDom();
  root = createRoot(container);
  const prompt = 'Check the "review" logs in `C:\\review`.';
  const call = { ...start("first"), prompt };
  const input = { name: "first", prompt, cwd: "unique-folder" };
  const rawTool = {
    id: "raw-search",
    title: "mcp__cmux-subsessions__start_session",
    status: "completed",
    inputSummary: JSON.stringify(input),
    output: "review complete",
  };
  const row: AcpmuxRow = {
    id: "row",
    kind: "activity",
    version: 1,
    at: 1,
    items: [{ kind: "tool", text: rawTool.title, tool: rawTool }],
  };
  for (const needle of ["review", "unique-folder"]) {
    await act(async () =>
      root!.render(
        <FindReveal.Provider value={{ rowId: "row", card: false, needle, repaint: () => {} }}>
          <div data-row-id="row">
            <SubsessionCallCard call={call} tool={rawTool} />
          </div>
        </FindReveal.Provider>,
      ),
    );
    const matches = findMatchesIncremental([row], needle).matches;
    expect(matches).toHaveLength(needle === "review" ? 3 : 1);
    for (const [index, match] of matches.entries()) {
      const range = paintFindHighlights(container, needle, { ...match, card: false })!;
      expect(range.toString()).toBe(needle);
      const inPrompt = Boolean(range.startContainer.parentElement?.closest(".cv-subsession__markdown"));
      expect(inPrompt).toBe(needle === "review" && index < 2);
      const highlights = (scope.CSS as { highlights: Map<string, { ranges: Range[] }> }).highlights;
      expect(highlights.get("acpmux-find")!.ranges).toHaveLength(matches.length - 1);
    }
    expect(container.querySelector(".cv-mcp-call__body")?.textContent).toBe(JSON.stringify(input, null, 2));
  }
});

test("Find highlights a prompt's link URL in Raw, including a query shared with visible Markdown", async () => {
  const container = installDom();
  root = createRoot(container);
  const prompt = "[design](https://example.com/unique-design-path)";
  const call = { ...start("first"), prompt };
  const rawTool = {
    id: "link-search",
    title: "mcp__cmux-subsessions__start_session",
    status: "completed",
    inputSummary: JSON.stringify({ name: "first", prompt }),
    output: "Started",
  };
  const row: AcpmuxRow = {
    id: "row",
    kind: "activity",
    version: 1,
    at: 1,
    items: [{ kind: "tool", text: rawTool.title, tool: rawTool }],
  };
  for (const needle of ["unique-design-path", "design", "unique-design-path"]) {
    await act(async () =>
      root!.render(
        <FindReveal.Provider value={{ rowId: "row", card: false, needle, repaint: () => {} }}>
          <div data-row-id="row">
            <SubsessionCallCard call={call} tool={rawTool} />
          </div>
        </FindReveal.Provider>,
      ),
    );
    const matches = findMatchesIncremental([row], needle).matches;
    expect(matches).toHaveLength(needle === "design" ? 2 : 1);
    for (const match of matches) {
      const range = paintFindHighlights(container, needle, { ...match, card: false });
      expect(range?.toString()).toBe(needle);
      expect(range?.startContainer.parentElement?.closest(".cv-mcp-call__body")).not.toBeNull();
      const highlights = (scope.CSS as { highlights: Map<string, { ranges: Range[] }> }).highlights;
      expect(highlights.get("acpmux-find")!.ranges).toHaveLength(matches.length - 1);
    }
  }
});

test("Find uses Raw for fenced code in a shadow root and Markdown while plain code is still in light DOM", () => {
  const container = installDom();
  const prompt = "```ts\nconst uniqueCodeMatch = 1;\n```";
  const rawTool = {
    id: "code-search",
    title: "mcp__cmux-subsessions__start_session",
    status: "completed",
    inputSummary: JSON.stringify({ prompt }),
    output: "Started",
  };
  const row: AcpmuxRow = {
    id: "row",
    kind: "activity",
    version: 1,
    at: 1,
    items: [{ kind: "tool", text: rawTool.title, tool: rawTool }],
  };
  // CodeBlock starts with PlainCode in the light DOM, then loads Pierre's shadow-root renderer.
  container.innerHTML =
    '<div data-row-id="row"><div data-find-primary="code"><pre>const uniqueCodeMatch = 1;</pre></div><pre data-find-fallback="code"></pre></div>';
  const primary = container.querySelector<HTMLElement>("[data-find-primary]")!;
  container.querySelector("[data-find-fallback]")!.textContent = JSON.stringify(prompt);
  const matches = findMatchesIncremental([row], "uniqueCodeMatch").matches;
  expect(matches).toHaveLength(1);
  const active = { ...matches[0]!, card: false };
  let range = paintFindHighlights(container, "uniqueCodeMatch", active);
  expect(primary.contains(range!.startContainer)).toBe(true);
  expect(
    (scope.CSS as { highlights: Map<string, { ranges: Range[] }> }).highlights.get("acpmux-find")!.ranges,
  ).toHaveLength(0);
  primary.replaceChildren();
  const code = document.createElement("div");
  code.attachShadow({ mode: "open" }).textContent = "const uniqueCodeMatch = 1;";
  primary.append(code);
  range = paintFindHighlights(container, "uniqueCodeMatch", active);
  expect(range?.toString()).toBe("uniqueCodeMatch");
  expect(range?.startContainer.parentElement?.closest("[data-find-fallback]")).not.toBeNull();
  const highlights = (scope.CSS as { highlights: Map<string, { ranges: Range[] }> }).highlights;
  expect(highlights.get("acpmux-find")!.ranges).toHaveLength(0);
});

test("group labels translate the complete sentence and choose the count's plural form", async () => {
  const container = installDom();
  root = createRoot(container);
  for (const [language, names, expected] of [
    ["en", ["tests"], "Started 1 sub-session: tests"],
    ["en", ["tests", "docs", "lint"], "Started 3 sub-sessions: tests, docs, lint"],
    ["de", ["tests", "docs", "lint"], "3 Untersitzungen gestartet: tests, docs, lint"],
    ["ja", ["tests", "docs", "lint"], "3 件のサブセッションを開始: tests, docs, lint"],
  ] as const) {
    await act(async () => {
      setPaneLanguage(language);
      root!.render(<SubsessionCallCard group={names.map((name) => ({ call: start(name), tool: tool(name) }))} />);
    });
    expect(container.querySelector(".cv-disclosure__label")?.textContent).toBe(expected);
  }
});
