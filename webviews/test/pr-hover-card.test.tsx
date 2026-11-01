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
  // The glyph follows the PR state and the status row names it for quick scanning.
  expect(card!.querySelector(".acpmux-pr-card__glyph svg")?.getAttribute("aria-label")).toBe("Draft");
  expect(card!.querySelector(".acpmux-pr-card__state")?.textContent).toBe("Draft");
  expect(shownText(card!)).toContain("Draft");
  expect(text).toContain("teamleaderleo");
  expect(card!.querySelector(".acpmux-pr-card__checks .acpmux-pr-card__sr")?.textContent).toBe(
    "7 of 9 checks passed, 2 failing",
  );
  expect(card!.querySelector(".acpmux-pr-card__failed")?.textContent).toBe("✗ 2");
}

/** The card's text as it shows: no svg titles and no screen-reader-only words. */
function shownText(element: Element): string {
  const copy = element.cloneNode(true) as Element;
  for (const hidden of copy.querySelectorAll("title, .acpmux-pr-card__sr")) hidden.remove();
  return copy.textContent ?? "";
}

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
  // The head's icon is the pull request glyph in its state's colour (draft here).
  expect(head.querySelector('.cv-link-preview__icon .acpmux-pr-card__glyph[data-state="draft"] svg')).not.toBeNull();
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
  expect(card.classList.contains("ui-glass")).toBe(true);
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

// Leo 2026-10-21: quiet borderless Open and Open in, tight spacing with no divider under the head,
// "+905 −50" with no dotted underline, and glass rather than a solid card.
test("the card's chrome is quiet: borderless buttons, no divider, no underline, a glass surface", async () => {
  const { readFileSync } = await import("node:fs");
  const path = await import("node:path");
  const styles = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/chips/linkCard.css"), "utf8");
  const rule = (selector: string) =>
    new RegExp(`(?:^|\\})${selector.replace(/[[\]().:]/g, "\\$&")}\\{([^}]*)\\}`, "m").exec(styles)?.[1] ?? "";
  const open = rule(".cv-link-preview__open");
  expect(open).toContain("border:0");
  expect(open).toContain("background:transparent");
  expect(open).not.toContain("box-shadow");
  expect(rule(".cv-link-preview .acpmux-open-in")).toContain("box-shadow:none");
  expect(rule(".cv-link-preview__head")).not.toContain("border");
  expect(rule(".acpmux-pr-card__lines")).toContain("display:inline-flex");
  // Glass: the shared liquid glass (.ui-glass) paints the card, so the card itself sets no fill;
  // plain glass and Reduce Transparency get the tooltip's tint and blur through the glass tokens.
  const card = rule(".cv-link-preview");
  expect(card).not.toContain("background");
  expect(card).not.toContain("box-shadow");
  expect(rule(".cv-link-preview.ui-card")).toContain("--glass-elevation:");
  const fallback = rule(':root:not([data-glass="lens"], [data-glass="spectrum"]) .cv-link-preview.ui-card.ui-glass');
  expect(fallback).toContain("--glass-tint:var(--tooltip-tint");
  expect(fallback).toContain("--glass-backdrop:var(--tooltip-blur");
});
