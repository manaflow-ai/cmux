// l10n-allow-file: test fixture titles and logins, not shipped UI.
// Leo 2026-10-20: a bare pull request reference in an agent's reply (`#634`, `(#634)`) is a link
// with the pull request's hover card. Its repository is the chat folder's GitHub remote, else the
// one the transcript mentioned last (`owner/repo#N` or a github.com URL), else the header pull
// request's. Code spans and code blocks never link.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "customElements",
  "getComputedStyle",
  "localStorage",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
// The code block's highlighted card (@pierre/diffs) defines its web component on import and builds
// its lines with the DOM's constructors (as in render-fence.test.tsx).
const domConstructors = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope) && !(keys as readonly string[]).includes(key),
);
const saved = [...keys, ...domConstructors].map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    customElements: dom.window.customElements,
    ...Object.fromEntries(domConstructors.map((key) => [key, (dom.window as unknown as Record<string, unknown>)[key]])),
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle,
    localStorage: dom.window.localStorage,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const REPO = "manaflow-ai/leo-workspace";
const URL = `https://github.com/${REPO}/pull/634`;
const TITLE = "rulebook: reviewed PRs merge right away";
const answer = {
  pullRequest: {
    url: URL,
    number: 634,
    title: TITLE,
    state: "open",
    review: "",
    mergeable: "",
    author: "teamleaderleo",
    checks: { state: "passing", passed: 3, total: 3 },
    checkList: [],
  },
};

// A failed expectation must not leave its root mounted for the next test.
let unmount: (() => Promise<void>) | undefined;
afterEach(async () => {
  await unmount?.();
  unmount = undefined;
});

async function render(text: string, githubRepository: string | undefined) {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { resetPullRequestStore } = await import("../src/agent-session/acpmux/chips/pullRequestStore");
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  resetLinkStore();
  resetPullRequestStore();
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    return method === "pr.inspect" ? answer : undefined;
  });
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  await act(async () =>
    root.render(
      <UiProvider container={element}>
        <Markdown githubRepository={githubRepository}>{text}</Markdown>
      </UiProvider>,
    ),
  );
  unmount = async () => {
    await act(async () => root.unmount());
    setChipHost(undefined);
  };
  return {
    element,
    calls,
    async hover(chip: HTMLElement) {
      await act(async () => chip.focus());
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    },
  };
}

test("a bare #N in a reply links to the pull request and opens its card", async () => {
  const view = await render("Landed in (#634).", REPO);
  const chips = [...view.element.querySelectorAll<HTMLAnchorElement>("a.cv-chip")];
  expect(chips.map((chip) => [chip.textContent, chip.getAttribute("href")])).toEqual([["#634", URL]]);
  await view.hover(chips[0]!);
  const card = view.element.querySelector<HTMLElement>(".cv-link-preview.acpmux-pr-card");
  expect(card).not.toBeNull();
  expect(card!.textContent).toContain(TITLE);
  expect(card!.textContent).toContain(`${REPO}#634`);
  // The chip's own ask reads the host's cache only (its mark's colour); the card's is the read.
  expect(view.calls.filter((call) => call.method === "pr.inspect")).toEqual([
    { method: "pr.inspect", params: { url: URL, cached: true } },
    { method: "pr.inspect", params: { url: URL } },
  ]);
});

// Leo 2026-10-23, of a merged pull request's blue chip: "I feel like this should be purple". The
// chip's mark takes its state from the host's cache, before any hover and without a GitHub read.
test("a pull request chip carries its state for its mark's colour", async () => {
  const view = await render("Landed in (#634).", REPO);
  const chip = view.element.querySelector<HTMLAnchorElement>("a.cv-chip.is-ref")!;
  await view.hover(chip);
  expect(chip.dataset.prState).toBe("open");
  const { readFileSync } = await import("node:fs");
  const css = readFileSync(new globalThis.URL("../src/agent-session/acpmux/chips/chips.css", import.meta.url), "utf8");
  expect(css).toMatch(
    /\.cv-chip\.is-ref\[data-pr-state="merged"\] \.cv-chip__icon--gh \{\s*color: var\(--agent-status-merged\);/,
  );
});

test("a reference in a code span or a code block is not a link", async () => {
  const view = await render("Prose #634, code `#635` and `a/b#636`.\n\n```\n#637 a/b#638\n```\n", REPO);
  // Finish loading the lazy card inside this test. Without a highlight worker (as in jsdom),
  // the card deliberately keeps its plain-code fallback; references must stay literal there too.
  const { act } = await import("react");
  const { loadHighlightedCode } = await import("../src/agent-session/acpmux/conversation/CodeBlock");
  await act(async () => {
    await loadHighlightedCode();
  });
  const code = view.element.querySelector(".cv-code-plain");
  const chips = [...view.element.querySelectorAll<HTMLAnchorElement>("a.cv-chip")];
  expect(chips.map((chip) => chip.getAttribute("href"))).toEqual([URL]);
  expect(view.element.textContent).toContain("#635");
  expect(code?.textContent).toBe("#637 a/b#638");
  expect(code?.querySelectorAll("a")).toHaveLength(0);
});

test("without the folder's remote, a bare #N takes the repository the transcript mentioned last", async () => {
  const { transcriptRepositories } = await import("../src/agent-session/acpmux/conversation/transcriptRepositories");
  const rows = [
    { id: "u1", kind: "user", text: "Review https://github.com/other/repo/pull/1 first" },
    { id: "a1", kind: "assistant", text: `Done. Next is ${REPO}#600; \`x/y#1\` is code.` },
    { id: "a2", kind: "assistant", text: "Landed in #634." },
  ];
  const repositories = transcriptRepositories(rows);
  expect(repositories).toEqual(["other/repo", REPO, REPO]);
  const view = await render(rows[2]!.text, repositories[2]);
  const chips = [...view.element.querySelectorAll<HTMLAnchorElement>("a.cv-chip")];
  expect(chips.map((chip) => chip.getAttribute("href"))).toEqual([URL]);
});

test("transcript repositories: the header pull request's repository is the last fallback; rows are read once", () => {
  return import("../src/agent-session/acpmux/conversation/transcriptRepositories").then(
    ({ transcriptRepositories }) => {
      const cache = new Map();
      const rows = [
        { id: "u1", kind: "user", text: "fix #3" },
        { id: "t1", kind: "activity", text: "a/b#1 in a tool's output" },
        { id: "a1", kind: "assistant", text: "see c/d#2" },
      ];
      expect(transcriptRepositories(rows, "h/r", cache)).toEqual(["h/r", "h/r", "c/d"]);
      expect([...cache.keys()]).toEqual(["u1", "a1"]);
      // A row whose text changed (a streaming reply) is read again.
      const grown = [...rows.slice(0, 2), { id: "a1", kind: "assistant", text: "see c/d#2, then e/f#4" }];
      expect(transcriptRepositories(grown, "h/r", cache)).toEqual(["h/r", "h/r", "e/f"]);
    },
  );
});
