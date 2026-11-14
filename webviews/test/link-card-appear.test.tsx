// l10n-allow-file: test fixture titles and logins, not shipped UI.
// Leo, 2026-11-06, on a GitHub link's hover card: "when I hover on a link, it plays this really
// laggy, slow animation for the GitHub ones. I want it to be fast". The card shows in the frame it
// opens in, with no fade and no rise (a rise moved its blur hole over the transcript every frame,
// ui/glass/seeThroughBlur.ts), and opens at its full size: while the host is still reading the pull
// request, placeholder rows hold the space its rows will take, so no row pops in after it shows.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { until } from "./support/until";
import { settleReact } from "./support/domTeardown";

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
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const PR_URL = "https://github.com/manaflow-ai/cmux/pull/37155";
const full = {
  pullRequest: {
    url: PR_URL,
    number: 37155,
    title: "fix(cmux-wg): a dial waiting on a handshake resends its initiation every second",
    state: "merged",
    author: "teamleaderleo",
    updatedAt: new Date(Date.now() - 5 * 60_000).toISOString(),
    additions: 86,
    deletions: 0,
    changedFiles: 3,
    files: [{ path: "cmux-wg/src/dial.rs", additions: 86, deletions: 0 }],
    baseRef: "feat-cmux-next",
    headRef: "lane/wg-dial-handshake-retry",
  },
  fetchedAt: Date.now() / 1000 - 5,
  reading: false,
};

/** A reply's pull request chip, focused so its card opens at once; the host answers `pr.inspect`
 * with whatever `answer()` says when it is asked. */
async function openCard(answer: (params: Record<string, unknown>) => unknown) {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { resetPullRequestStore } = await import("../src/agent-session/acpmux/chips/pullRequestStore");
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  setPaneLanguage("en");
  resetPullRequestStore();
  resetLinkStore();
  setChipHost(async (method, params) => (method === "pr.inspect" ? answer(params) : undefined));
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  await act(async () =>
    root.render(
      <UiProvider container={element}>
        <UrlChip href={PR_URL}>manaflow-ai/cmux#37155</UrlChip>
      </UiProvider>,
    ),
  );
  await act(async () => element.querySelector<HTMLElement>("a.cv-chip")!.focus());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const card = () => element.querySelector<HTMLElement>(".cv-link-preview.acpmux-pr-card");
  return {
    card,
    act,
    done: async () => {
      await act(async () => root.unmount());
      setChipHost(undefined);
    },
  };
}

test("a pull request link's card shows at once: no fade in and no rise", async () => {
  const opened = await openCard(() => full);
  try {
    const card = opened.card();
    expect(card).not.toBeNull();
    // desktop.css: a [data-instant] tooltip has no transition (not its opacity, not its rise).
    expect(card!.hasAttribute("data-instant")).toBe(true);
  } finally {
    await opened.done();
  }
});

test("while the host reads, placeholder rows hold the card at its full size; the answer replaces them", async () => {
  let answer: unknown = { pullRequest: null, reading: true };
  const opened = await openCard(() => answer);
  try {
    const card = opened.card()!;
    const rows = [...card.querySelectorAll<HTMLElement>("[data-placeholder]")].map((row) => row.dataset.placeholder);
    // The rows the answer brings: its state, its author, its two change lines and its branches.
    expect(rows).toEqual(["status", "who", "changes", "branches"]);
    for (const row of card.querySelectorAll("[data-placeholder]")) expect(row.getAttribute("aria-hidden")).toBe("true");
    // What the chat already knows still shows.
    expect(card.textContent).toContain("manaflow-ai/cmux#37155");
    // The answer lands on the next ask (the store asks again while the host reads; here, now).
    answer = full;
    const { askPullRequest, pullRequestAnswer } = await import("../src/agent-session/acpmux/chips/pullRequestStore");
    await opened.act(async () => askPullRequest(PR_URL));
    await until(
      () => Boolean(pullRequestAnswer(PR_URL)?.pullRequest),
      () => opened.act(async () => {}),
    );
    expect(pullRequestAnswer(PR_URL)?.pullRequest?.number).toBe(37155);
    // A crossfade in place (Leo 2026-11-08: "a bit too discontinuous and jumpy"): each row the
    // answer fills shares one grid cell with the placeholder it replaces, the row first, the
    // placeholder over it fading out; a row the answer leaves empty (none here) drops its
    // placeholder in the same frame.
    const slots = [...card.querySelectorAll<HTMLElement>(".acpmux-pr-card__slot")].filter((slot) =>
      slot.lastElementChild?.hasAttribute("data-placeholder"),
    );
    expect(slots.map((slot) => slot.lastElementChild?.getAttribute("data-placeholder"))).toEqual([
      "status",
      "who",
      "changes",
      "branches",
    ]);
    for (const slot of slots) expect(slot.firstElementChild?.hasAttribute("data-placeholder")).toBe(false);
    expect(card.querySelector(".acpmux-pr-card__body")?.hasAttribute("data-load-fade")).toBe(true);
    // Each placeholder goes on its own fade's end, no timer: one ending leaves the others to finish
    // theirs (review of #38163, F1), and its row stays the same element, so its fade never restarts.
    const who = card.querySelector(".acpmux-pr-card__who:not([data-placeholder])");
    const end = async (row: string) =>
      opened.act(async () => {
        const ended = card.querySelector(`.acpmux-pr-card__slot > [data-placeholder="${row}"]`)!;
        ended.dispatchEvent(new dom.window.Event("animationend", { bubbles: true }));
      });
    await end("who");
    expect([...card.querySelectorAll<HTMLElement>("[data-placeholder]")].map((row) => row.dataset.placeholder)).toEqual(
      ["status", "changes", "branches"],
    );
    expect(card.querySelector(".acpmux-pr-card__who:not([data-placeholder])")).toBe(who);
    for (const row of ["status", "changes", "branches"]) await end(row);
    expect(card.querySelector("[data-placeholder]")).toBeNull();
    expect(card.querySelector(".acpmux-pr-card__who:not([data-placeholder])")).toBe(who);
    expect(card.querySelector(".acpmux-pr-card__who")?.textContent).toContain("teamleaderleo");
    expect(card.querySelector(".acpmux-pr-card__branches")?.textContent).toContain("feat-cmux-next");
  } finally {
    await opened.done();
  }
});

test("a chip's cache-only ask that found nothing still opens the card with its rows held", async () => {
  // The chip asked the host's cache when it drew and got nothing; the card's own ask starts the
  // read. Until that ask answers, the card is not empty: it is about to be read.
  const opened = await openCard((params) =>
    params.cached ? { pullRequest: null, reading: false } : new Promise(() => {}),
  );
  try {
    expect(opened.card()!.querySelectorAll("[data-placeholder]").length).toBe(4);
  } finally {
    await opened.done();
  }
});

test("a settled answer stays settled when a later cache-only ask finds nothing (review of #37192, F3)", async () => {
  const cacheAsks: unknown[] = [];
  const opened = await openCard((params) => {
    if (params.cached) cacheAsks.push(params);
    return { pullRequest: null, reading: false };
  });
  try {
    const { askPullRequest, pullRequestAnswer } = await import("../src/agent-session/acpmux/chips/pullRequestStore");
    const asked = cacheAsks.length;
    // An answer the same as the one held changes nothing to wait on: the host taking the ask is the
    // signal, and the act it lands in returns only after a task turn, once the store took the reply.
    await opened.act(async () => askPullRequest(PR_URL));
    await until(
      () => cacheAsks.length > asked,
      () => opened.act(async () => {}),
    );
    expect(pullRequestAnswer(PR_URL)?.cacheOnly).toBeUndefined();
    expect(opened.card()!.querySelector("[data-placeholder]")).toBeNull();
  } finally {
    await opened.done();
  }
});

test("a host with nothing to say and not reading leaves no placeholder behind", async () => {
  const opened = await openCard(() => ({ pullRequest: null, reading: false }));
  try {
    expect(opened.card()!.querySelector("[data-placeholder]")).toBeNull();
  } finally {
    await opened.done();
  }
});

test("the placeholder bars are static: no shimmer animation, no transition", async () => {
  const { readFileSync } = await import("node:fs");
  const path = await import("node:path");
  const styles = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/chips/linkCard.css"), "utf8");
  const bar = /\.acpmux-pr-card__bar\{([^}]*)\}/.exec(styles)?.[1];
  expect(bar).toBeDefined();
  expect(bar).not.toContain("animation");
  expect(bar).not.toContain("transition");
});

// Leo 2026-11-08: "we're almost, like, streaming in the first hover preview". The pointer reaching
// the link asks the host at once, a second before the card's dwell ends, so the read runs during
// the dwell and the card opens with its answer in hand.
test("the pointer reaching a pull request link asks the host before the card opens", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { resetPullRequestStore, pullRequestAnswer } =
    await import("../src/agent-session/acpmux/chips/pullRequestStore");
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  resetPullRequestStore();
  const asked: Record<string, unknown>[] = [];
  setChipHost(async (method, params) => {
    if (method !== "pr.inspect") return undefined;
    asked.push(params);
    return full;
  });
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  try {
    await act(async () =>
      root.render(
        <UiProvider container={element}>
          <UrlChip href={PR_URL}>manaflow-ai/cmux#37155</UrlChip>
        </UiProvider>,
      ),
    );
    const link = element.querySelector<HTMLElement>("a.cv-chip")!;
    await act(async () => {
      link.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true, clientX: 4, clientY: 4 }));
    });
    await until(
      () => pullRequestAnswer(PR_URL) !== undefined,
      () => act(async () => {}),
    );
    // The card is not open yet (its dwell runs), and the full read was asked for.
    expect(element.querySelector(".cv-link-preview")).toBeNull();
    expect(asked.some((params) => params.url === PR_URL && params.cached === undefined)).toBe(true);
    expect(pullRequestAnswer(PR_URL)?.pullRequest?.number).toBe(37155);
  } finally {
    await act(async () => root.unmount());
    setChipHost(undefined);
  }
});
