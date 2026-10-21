// l10n-allow-file: test fixture titles and logins, not shipped UI.
// Leo 2026-10-20: a pull request's cut-off title is worth a hover, but on a styled card, not the
// system tooltip. A pull request bar above the composer and a pull request chip in a reply open
// one card (chips/PullRequestCard.tsx): the full title, owner/repo#N, its state, its author and
// its checks, as `gh pr view` reads them (`pr.inspect`). Until the host answers, the card shows
// what the chat already knows.
import { afterAll, beforeAll, expect, test } from "bun:test";
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
  "getComputedStyle",
  "localStorage",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
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

const URL = "https://github.com/manaflow-ai/leo-workspace/pull/634";
const TITLE = "rulebook: reviewed PRs merge right away; the label is the fallback when the owner cannot merge";
const answer = {
  pullRequest: {
    url: URL,
    number: 634,
    title: TITLE,
    state: "draft",
    review: "",
    mergeable: "",
    author: "teamleaderleo",
    checks: { state: "failing", passed: 7, total: 9 },
    checkList: [],
  },
};

const tool = (id: string, command: string, output = "") => ({
  id,
  tool: { id, kind: "execute", title: command, status: "completed", exitCode: 0, command, output },
});

async function rig() {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { resetPullRequestStore } = await import("../src/agent-session/acpmux/chips/pullRequestStore");
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  resetPullRequestStore();
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    return method === "pr.inspect" ? answer : undefined;
  });
  return { calls, done: () => setChipHost(undefined) };
}

function expectFullCard(card: HTMLElement | null) {
  expect(card).not.toBeNull();
  const text = card!.textContent ?? "";
  expect(text).toContain(TITLE);
  expect(text).toContain("manaflow-ai/leo-workspace#634");
  expect(text).toContain("Draft");
  expect(text).toContain("teamleaderleo");
  expect(text).toContain("7 of 9 checks passed, 2 failing");
}

test("a pull request bar opens the pull request card", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { PullRequestDock } = await import("../src/agent-session/acpmux/summary/PullRequestDock");
  const host = await rig();
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  const rows = [
    { kind: "activity", id: "a1", version: 1, items: [tool("t1", `gh pr create --title "${TITLE}"`, URL)] },
  ];
  await act(async () =>
    root.render(
      <UiProvider container={element}>
        <PullRequestDock rows={rows as never} sessionId="card" />
      </UiProvider>,
    ),
  );
  const bar = element.querySelector<HTMLElement>(".acpmux-pr-dock__bar")!;
  await act(async () => bar.focus());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expectFullCard(element.querySelector<HTMLElement>(".acpmux-pr-card"));
  expect(host.calls.filter((call) => call.method === "pr.inspect")).toEqual([
    { method: "pr.inspect", params: { url: URL } },
  ]);
  // The bar itself carries no tooltip: the card is the hover.
  expect(bar.hasAttribute("title")).toBe(false);
  await act(async () => root.unmount());
  host.done();
});

test("a pull request chip in a reply opens the same card", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  resetLinkStore();
  const host = await rig();
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  await act(async () =>
    root.render(
      <UiProvider container={element}>
        <UrlChip href={URL}>manaflow-ai/leo-workspace#634</UrlChip>
      </UiProvider>,
    ),
  );
  await act(async () => element.querySelector<HTMLElement>("a.cv-chip")!.focus());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const card = element.querySelector<HTMLElement>(".cv-link-preview.acpmux-pr-card");
  expectFullCard(card);
  // It keeps the link card's Open, and its title sits in the head beside the GitHub mark.
  expect(card!.querySelector("button")?.textContent).toContain("Open");
  const head = card!.querySelector<HTMLElement>(".cv-link-preview__head")!;
  expect(head.querySelector(".cv-link-preview__icon svg")).not.toBeNull();
  expect(head.querySelector(".cv-link-preview__site")?.textContent).toBe(TITLE);
  // No address line: the head and owner/repo#N already say where it is (Leo 2026-10-21).
  expect(card!.querySelector(".cv-link-preview__target")).toBeNull();
  expect(card!.textContent).not.toContain("https://");
  await act(async () => root.unmount());
  host.done();
});

test("an inline link opens the same card: favicon, page title, host, the address with its secrets masked", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const { resetLinkStore, seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const link = "https://docs.example.test/guide?page=2&token=abc123";
  resetLinkStore();
  seedLinkStore({ sites: { [link]: { title: "Example Guide", icon: "data:image/png;base64,AA==" } } });
  const host = await rig();
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  await act(async () =>
    root.render(
      <UiProvider container={element}>
        <UrlChip href={link}>{link}</UrlChip>
      </UiProvider>,
    ),
  );
  await act(async () => element.querySelector<HTMLElement>("a.cv-chip")!.focus());
  const card = element.querySelector<HTMLElement>(".cv-link-preview")!;
  expect(card.classList.contains("acpmux-pr-card")).toBe(false);
  expect(card.querySelector(".cv-link-preview__icon img")).not.toBeNull();
  expect(card.querySelector(".cv-link-preview__site")?.textContent).toBe("Example Guide");
  expect(card.querySelector(".cv-link-preview__target")?.textContent).toBe(
    "https://docs.example.test/guide?page=2&token=•••",
  );
  expect([...card.querySelectorAll("button")].map((button) => button.textContent)).toEqual(
    expect.arrayContaining([expect.stringContaining("Open"), expect.stringContaining("Open in")]),
  );
  // No pull request, no gh read.
  expect(host.calls.some((call) => call.method === "pr.inspect")).toBe(false);
  await act(async () => root.unmount());
  host.done();
});
