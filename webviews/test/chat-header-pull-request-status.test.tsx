// The PR chip's status popover (cx-ncc.77.1, Codex desktop's PR status): the chip says the pull
// request's state and checks in its name, and clicking it lists the title, the review decision and
// each check, failing first, each linking its run. The App pushes it all with the header state.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // The popover places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));

test("the chip names the pull request's state and checks, and opens a list of each check", async () => {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () =>
    root.render(<ChatHeaderTools onTerminal={() => {}} onBrowser={() => {}} summary={null} menu={() => []} />),
  );
  const pullRequest = {
    url: "https://github.com/o/r/pull/7",
    number: 7,
    title: "Stage single hunks",
    state: "open",
    review: "changes_requested",
    mergeable: "mergeable",
    checks: { state: "failing", passed: 1, total: 3 },
    checkList: [
      { name: "build", state: "failed", url: "https://github.com/o/r/actions/runs/1" },
      { name: "test", state: "pending" },
      { name: "ci/lint", state: "passed", url: "https://ci.example/2" },
    ],
  };
  await act(async () => applyHostEvent({ kind: "headerState", value: { version: 1, pullRequest } }));
  try {
    const chip = host.querySelector<HTMLButtonElement>("button.acpmux-header-pr");
    expect(chip?.textContent).toBe("#7");
    expect(chip?.getAttribute("aria-label")).toBe("Pull request #7, open: 1 of 3 checks passed, 1 failing");
    await act(async () => chip!.click());
    await settle();
    const popover = dom.window.document.querySelector(".acpmux-pr-status");
    expect(popover?.querySelector(".acpmux-pr-title")?.textContent).toBe("Stage single hunks");
    expect(popover?.querySelector<HTMLAnchorElement>("a.acpmux-pr-title")?.href).toBe("https://github.com/o/r/pull/7");
    expect(popover?.querySelector(".acpmux-pr-review")?.textContent).toBe("Changes requested");
    const rows = [...(popover?.querySelectorAll<HTMLElement>(".acpmux-pr-check") ?? [])];
    expect(rows.map((row) => [row.dataset.state, row.textContent])).toEqual([
      ["failed", "build"],
      ["pending", "test"],
      ["passed", "ci/lint"],
    ]);
    expect(rows[0]!.querySelector("a")?.getAttribute("href")).toBe("https://github.com/o/r/actions/runs/1");
    expect(rows[1]!.querySelector("a")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a failing check the base branch's tip fails too says so on its own row", async () => {
  // Base reds do not hold a pull request (CLAUDE.md's merge rules), so the row that is already red
  // on the base is marked rather than left to look like work: its dot drops from danger to warning
  // and it reads "also red on base". The host decides which ones those are
  // (AgentPanePullRequest `failingOnBase`, newest run per workflow only, so a cancelled run that a
  // newer one replaced can never excuse a red); the page only draws the answer.
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () =>
    root.render(<ChatHeaderTools onTerminal={() => {}} onBrowser={() => {}} summary={null} menu={() => []} />),
  );
  const pullRequest = {
    url: "https://github.com/o/r/pull/7",
    number: 7,
    title: "Stage single hunks",
    state: "open",
    review: "",
    mergeable: "mergeable",
    checks: { state: "failing", passed: 1, total: 3, failingOnBase: 1 },
    checkList: [
      { name: "build", state: "failed", onBase: true },
      { name: "test", state: "failed" },
      { name: "ci/lint", state: "passed" },
    ],
  };
  await act(async () => applyHostEvent({ kind: "headerState", value: { version: 7, pullRequest } }));
  try {
    const chip = host.querySelector<HTMLButtonElement>("button.acpmux-header-pr");
    await act(async () => chip!.click());
    await settle();
    const popover = dom.window.document.querySelector(".acpmux-pr-status");
    const rows = [...(popover?.querySelectorAll<HTMLElement>(".acpmux-pr-check") ?? [])];
    expect(rows.map((row) => [row.dataset.state, row.dataset.onBase, row.textContent])).toEqual([
      ["failed", "", "buildalso red on base"],
      ["failed", undefined, "test"],
      ["passed", undefined, "ci/lint"],
    ]);
  } finally {
    await act(async () => root.unmount());
  }
});
