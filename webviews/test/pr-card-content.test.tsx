// l10n-allow-file: test fixture titles, logins and branch names, not shipped UI.
// Leo 2026-10-20 asked for one pull request card for every pull request cmux mentions, as good as
// Claude's: the title, state and checks, the author and when GitHub last saw it change, a compact
// diff summary, and secondary branch, review and label context. And it must read cmux's own cache: Leo's
// card showed "GitHub rate limit · resets 9:11 PM" because every hover called GitHub.
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

// Not `URL`: a const of that name shadows the global constructor for the whole file.
const PR_URL = "https://github.com/manaflow-ai/cmux/pull/22777";
const KNOWN = { repo: "manaflow-ai/cmux", number: 22777 };
const FILES = [
  { path: "webviews/src/agent-session/acpmux/chips/PullRequestCard.tsx", additions: 200, deletions: 40 },
  { path: "webviews/test/pr-card-content.test.tsx", additions: 150, deletions: 0 },
  { path: "webviews/src/agent-session/acpmux/mockFixture.ts", additions: 12, deletions: 3 },
  { path: "docs/ci/risk-tiers.md", additions: 9, deletions: 2 },
  { path: "bun.lock", additions: 1_000, deletions: 20 },
];

function pullRequest(extra: Record<string, unknown> = {}) {
  return {
    url: PR_URL,
    number: 22777,
    title: "One pull request card for every pull request cmux mentions",
    state: "open",
    review: "changes_requested",
    mergeable: "conflicting",
    author: "teamleaderleo",
    updatedAt: new Date(Date.now() - 3 * 60_000).toISOString(),
    baseRef: "feat-cmux-next",
    headRef: "cmux/pr-cards",
    labels: ["risk:normal", "agent"],
    additions: 1_371,
    deletions: 65,
    changedFiles: FILES.length,
    files: FILES,
    checks: { state: "failing", passed: 89, total: 100 },
    checkList: [{ name: "cmux-next generated files", state: "failed" }],
    ...extra,
  };
}

let teardown: (() => Promise<void>) | undefined;
/** Unmounts the card a test drew, so the test can draw another. */
async function unmount() {
  await teardown?.();
  teardown = undefined;
}
afterEach(unmount);

/** Renders the card body against a host that answers `pr.inspect` with `answer`. */
async function card(answer: Record<string, unknown>) {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  // The card words every age in the pane's language, so the pane's language is pinned here
  // rather than left to the runner's (REVIEW.md: a test must not read the machine).
  setPaneLanguage("en");
  const { resetPullRequestStore } = await import("../src/agent-session/acpmux/chips/pullRequestStore");
  const { PullRequestCardBody } = await import("../src/agent-session/acpmux/chips/PullRequestCard");
  const calls: string[] = [];
  resetPullRequestStore();
  setChipHost(async (method) => {
    calls.push(method);
    return method === "pr.inspect" ? answer : undefined;
  });
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  await act(async () =>
    root.render(
      <UiProvider container={element}>
        <PullRequestCardBody url={PR_URL} known={KNOWN} open />
      </UiProvider>,
    ),
  );
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  teardown = async () => {
    await act(async () => root.unmount());
    setChipHost(undefined);
  };
  return { element, body: element.querySelector<HTMLElement>(".acpmux-pr-card__body")!, calls, act };
}

/** The card's text as it shows: no svg titles and no screen-reader-only words. */
function shownText(element: Element): string {
  const copy = element.cloneNode(true) as Element;
  for (const hidden of copy.querySelectorAll("title, .acpmux-pr-card__sr")) hidden.remove();
  return copy.textContent ?? "";
}

test("the card prioritizes the title, state and checks, then author and diff context", async () => {
  const { body } = await card({ pullRequest: pullRequest(), fetchedAt: Date.now() / 1000 - 5 });
  const text = body.textContent ?? "";
  expect(body.querySelector(".acpmux-pr-card__state")?.textContent).toBe("Open");
  expect(body.querySelector(".acpmux-pr-card__glyph svg")?.getAttribute("aria-label")).toBe("Open");
  expect(body.querySelector(".acpmux-pr-card__glyph")?.getAttribute("data-state")).toBe("open");
  expect(body.querySelector(".acpmux-pr-card__conflicts")?.textContent).toBe("Has conflicts");
  expect(text).toContain("manaflow-ai/cmux#22777");
  expect(text).toContain("One pull request card for every pull request cmux mentions");
  expect(text).toContain("teamleaderleo");
  expect(text).toContain("updated 3 minutes ago");
  expect(body.querySelector(".acpmux-pr-card__monogram")?.textContent).toBe("T");
  expect([...body.querySelectorAll(".acpmux-pr-card__branch")].map((part) => part.textContent)).toEqual([
    "feat-cmux-next",
    "cmux/pr-cards",
  ]);
  expect(body.querySelector(".acpmux-pr-card__checks .acpmux-pr-card__sr")?.textContent).toBe(
    "89 of 100 checks passed, 1 failing",
  );
  expect(text).toContain("Changes requested");
  expect([...body.querySelectorAll(".acpmux-pr-card__label")].map((part) => part.textContent)).toEqual([
    "risk:normal",
    "agent",
  ]);
  expect(text).toContain("5 files");
  expect(text).toContain("+1,371");
  expect(text).toContain("−65");
});

// Leo 2026-10-20: "ones with links ... the hovers need to be styled". The card's owner/repo#N is
// the pull request's link, blue like every link in the pane (.cv-link), not grey text: a click on
// it takes the host's link-click path, as the bar's and the chip's own anchors do.
test("the card's owner/repo#N is a styled link to the pull request", async () => {
  const { body } = await card({ pullRequest: pullRequest(), fetchedAt: Date.now() / 1000 - 5 });
  const ref = body.querySelector<HTMLAnchorElement>("a.acpmux-pr-card__ref");
  expect(ref).not.toBeNull();
  expect(ref!.getAttribute("href")).toBe(PR_URL);
  expect(ref!.textContent).toBe("manaflow-ai/cmux#22777");
  // The card is what replaces system tooltips, so its link grows none.
  expect(ref!.hasAttribute("title")).toBe(false);
  const { readFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const styles = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/chips/linkCard.css"), "utf8");
  const rule = styles.match(/\.acpmux-pr-card__ref\{([^}]*)\}/)?.[1] ?? "";
  expect(rule).toContain("color:var(--agent-link)");
  expect(rule).toContain("text-decoration:underline");
  expect(rule).toContain("tabular-nums");
});

test("a card whose address is not a pull request link keeps owner/repo#N as text", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { PullRequestCardBody } = await import("../src/agent-session/acpmux/chips/PullRequestCard");
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  await act(async () =>
    root.render(
      <UiProvider container={element}>
        <PullRequestCardBody url="https://example.test/not-a-pull" known={KNOWN} open={false} />
      </UiProvider>,
    ),
  );
  const ref = element.querySelector(".acpmux-pr-card__ref");
  expect(ref?.tagName).toBe("SPAN");
  expect(element.querySelector("a")).toBeNull();
  await act(async () => root.unmount());
});

test("the diff breakdown stays inline without a nested card", async () => {
  const { body } = await card({ pullRequest: pullRequest(), fetchedAt: Date.now() / 1000 - 5 });
  expect(body.querySelector(".acpmux-pr-card__kinds")).toBeNull();
  expect(body.querySelector(".acpmux-pr-card__lines")?.tagName).toBe("SPAN");
  expect(body.querySelector(".acpmux-pr-card__breakdown")?.textContent).toContain(
    "Code+200−40·Tests+150·Mocks+12−3·Docs+9−2·Generated+1,000−20",
  );
});

test("code changed with no test gets a warning; a change with a test does not", async () => {
  const code = [{ path: "webviews/src/agent-session/acpmux/Composer.tsx", additions: 41, deletions: 9 }];
  const warned = await card({
    pullRequest: pullRequest({ files: code, changedFiles: 1, additions: 41, deletions: 9 }),
    fetchedAt: Date.now() / 1000 - 5,
  });
  expect(warned.body.querySelector(".acpmux-pr-card__warning")?.textContent).toBe("no tests");
  // One file counts as one, not "1 files".
  expect(warned.body.querySelector(".acpmux-pr-card__files")?.textContent).toBe("1 file");
  await teardown?.();
  teardown = undefined;
  const tested = await card({ pullRequest: pullRequest(), fetchedAt: Date.now() / 1000 - 5 });
  expect(tested.body.querySelector(".acpmux-pr-card__warning")).toBeNull();
});

test("a truncated file read says the inline breakdown is partial", async () => {
  const files = Array.from({ length: 2 }, (_, index) => ({
    path: `webviews/src/agent-session/acpmux/file-${index}.tsx`,
    additions: 10,
    deletions: 1,
  }));
  const { body } = await card({
    pullRequest: pullRequest({ files, changedFiles: 3, additions: 20, deletions: 2 }),
    fetchedAt: Date.now() / 1000 - 5,
  });
  expect(body.querySelector(".acpmux-pr-card__kindPartial")?.textContent).toBe("the first 2 files");
});

test("an answer cmux read a while ago says its age instead of looking current", async () => {
  const fresh = await card({ pullRequest: pullRequest(), fetchedAt: Date.now() / 1000 - 5 });
  expect(fresh.body.querySelector(".acpmux-pr-card__age")).toBeNull();
  await teardown?.();
  teardown = undefined;
  const stale = await card({ pullRequest: pullRequest(), fetchedAt: Date.now() / 1000 - 23 * 60 });
  expect(stale.body.querySelector(".acpmux-pr-card__age")?.textContent).toBe("read 23 minutes ago");
  // And nothing in the card is a GitHub call: it asked the app once and drew what it had.
  expect(stale.calls).toEqual(["pr.inspect"]);
});

test("a date the card cannot read costs it that one line, not the whole card", async () => {
  // Every date on a card comes from GitHub through the host, as a string the page never checked.
  // `Intl.DateTimeFormat` raises RangeError on an unparsed one, and a raise in a render takes the
  // card down to a blank, so the line is drawn only when its time is a real time.
  const { body } = await card({
    pullRequest: pullRequest({ updatedAt: "last Tuesday" }),
    fetchedAt: Date.now() / 1000 - 5,
  });
  expect(body.querySelector(".acpmux-pr-card__when")).toBeNull();
  // The rest of the card is still there.
  expect(body.textContent).toContain("teamleaderleo");
  expect(body.textContent).toContain("manaflow-ai/cmux#22777");
});

test("a read that answered nothing and is not running says nothing, instead of reading forever", async () => {
  // No gh on the PATH, or a pull request this account cannot see: the host tried, has no answer,
  // and will not try again for five minutes. "reading…" there is a lie that never resolves, so
  // the card falls back to what the reply itself knows.
  const { body } = await card({ pullRequest: null, reading: false });
  expect(body.querySelector(".acpmux-pr-card__age")).toBeNull();
  expect(body.textContent).toContain("manaflow-ai/cmux#22777");
});

test("no answer yet: the card says it is reading and keeps asking the app, not GitHub", async () => {
  const { body, calls } = await card({ pullRequest: null, reading: true });
  expect(body.querySelector(".acpmux-pr-card__age")?.textContent).toBe("reading…");
  // What the chat already knows is still there.
  expect(body.textContent).toContain("manaflow-ai/cmux#22777");
  expect(calls.every((method) => method === "pr.inspect")).toBe(true);
});

// Leo 2026-10-21, on a #22826 card: the state is carried by the glyph and a quiet status label,
// with merged using the theme purple, as GitHub draws it.
test("the glyph follows state and the card names that state in its status row", async () => {
  for (const [state, label] of [
    ["open", "Open"],
    ["merged", "Merged"],
    ["closed", "Closed"],
    ["draft", "Draft"],
  ] as const) {
    const { body } = await card({ pullRequest: pullRequest({ state, mergeable: "" }), fetchedAt: Date.now() / 1000 });
    const glyph = body.querySelector(".acpmux-pr-card__glyph")!;
    expect(glyph.getAttribute("data-state")).toBe(state);
    expect(glyph.querySelector("svg")?.getAttribute("aria-label")).toBe(label);
    expect(glyph.querySelector("svg")).not.toBeNull();
    expect(body.querySelector(".acpmux-pr-card__state")?.textContent).toBe(label);
    expect(shownText(body)).toContain(label);
    await unmount();
  }
  const { readFileSync } = await import("node:fs");
  const path = await import("node:path");
  const styles = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/chips/linkCard.css"), "utf8");
  const colour = (state: string) =>
    new RegExp(`\\.acpmux-pr-card__glyph\\[data-state=${state}\\]\\{color:([^}]*)\\}`).exec(styles)?.[1];
  expect(colour("open")).toContain("--agent-status-success");
  expect(colour("merged")).toContain("--agent-status-merged");
  expect(colour("closed")).toContain("--agent-status-failure");
  expect(styles).toContain(".acpmux-pr-card__state");
});

test("an open pull request's checks are a compact ✓/✗ count; a merged or closed one's are gone", async () => {
  const open = await card({
    pullRequest: pullRequest({ checks: { state: "failing", passed: 90, total: 100 }, checkList: [] }),
    fetchedAt: Date.now() / 1000,
  });
  const checks = open.body.querySelector<HTMLElement>(".acpmux-pr-card__checks")!;
  expect(checks.querySelector(".acpmux-pr-card__passed")?.textContent).toBe("✓ 90");
  expect(checks.querySelector(".acpmux-pr-card__failed")?.textContent).toBe("✗ 10");
  expect(checks.querySelector(".acpmux-pr-card__sr")?.textContent).toBe("90 of 100 checks passed, 10 failing");
  await unmount();
  const running = await card({
    pullRequest: pullRequest({ checks: { state: "pending", passed: 12, total: 40 }, checkList: [] }),
    fetchedAt: Date.now() / 1000,
  });
  const pending = running.body.querySelector<HTMLElement>(".acpmux-pr-card__checks")!;
  expect(pending.querySelector(".acpmux-pr-card__passed")?.textContent).toBe("✓ 12");
  expect(pending.querySelector(".acpmux-pr-card__failed")).toBeNull();
  expect(pending.querySelector(".acpmux-pr-card__pending")?.textContent).toBe("◷ 28");
  await unmount();
  for (const state of ["merged", "closed"]) {
    const ended = await card({
      pullRequest: pullRequest({
        state,
        mergeable: "conflicting",
        checks: { state: "failing", passed: 90, total: 100 },
      }),
      fetchedAt: Date.now() / 1000,
    });
    expect(ended.body.querySelector(".acpmux-pr-card__checks")).toBeNull();
    // Nor does a finished pull request still "have conflicts".
    expect(ended.body.querySelector(".acpmux-pr-card__conflicts")).toBeNull();
    await unmount();
  }
});

// A red the base branch's tip has too is not this pull request's: the merge rules say so, and the
// card says which of its reds those are, so nobody opens a log that was already red before the
// branch existed. The host decides (AgentPanePullRequest `failingOnBase`, which compares only each
// workflow's newest run so a cancelled, superseded run can never excuse a red); the card reads it.
test("the card says how many of the failing checks are also red on the base", async () => {
  const { body } = await card({
    pullRequest: pullRequest({
      checks: { state: "failing", passed: 98, total: 100, failingOnBase: 1 },
      checkList: [
        { name: "cmux-next generated files", state: "failed", onBase: true },
        { name: "web lint (fast)", state: "failed" },
      ],
    }),
    fetchedAt: Date.now() / 1000 - 5,
  });
  const checks = body.querySelector<HTMLElement>(".acpmux-pr-card__checks")!;
  expect(checks.querySelector(".acpmux-pr-card__sr")?.textContent).toBe(
    "98 of 100 checks passed, 2 failing, 1 also red on base",
  );
  expect(checks.querySelector(".acpmux-pr-card__failed")?.textContent).toBe("✗ 2");
  expect(checks.querySelector(".acpmux-pr-card__onBase")?.textContent).toBe("(1 already on base)");
  // One red is still this pull request's, so its ✗ stays danger.
  expect(checks.dataset.onBase).toBeUndefined();
});

test("every red being the base's reads the ✗ muted", async () => {
  const { body } = await card({
    pullRequest: pullRequest({
      checks: { state: "failing", passed: 98, total: 100, failingOnBase: 2 },
      checkList: [
        { name: "cmux-next generated files", state: "failed", onBase: true },
        { name: "web lint (fast)", state: "failed", onBase: true },
      ],
    }),
    fetchedAt: Date.now() / 1000 - 5,
  });
  const checks = body.querySelector<HTMLElement>(".acpmux-pr-card__checks")!;
  expect(checks.querySelector(".acpmux-pr-card__sr")?.textContent).toBe(
    "98 of 100 checks passed, 2 failing, 2 also red on base",
  );
  expect(checks.querySelector(".acpmux-pr-card__onBase")?.textContent).toBe("(2 already on base)");
  expect(checks.dataset.onBase).toBe("all");
  // Nothing here is this pull request's to fix (Leo 2026-10-21): the line reads in the muted text
  // colour, neither danger pink nor the warning colour.
  const { readFileSync } = await import("node:fs");
  const path = await import("node:path");
  const styles = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/chips/linkCard.css"), "utf8");
  const rule = (selector: string) =>
    new RegExp(`${selector.replace(/[[\]().]/g, "\\$&")}\\{([^}]*)\\}`).exec(styles)?.[1] ?? "";
  const failed = rule(".acpmux-pr-card__checks[data-state=failing][data-on-base=all] .acpmux-pr-card__failed");
  expect(failed).toContain("color:var(--agent-muted)");
  expect(failed).not.toContain("danger");
  expect(failed).not.toContain("warning");
});

test("a host that claims nothing about the base draws the card it always did", async () => {
  // The single-link path reads one `gh pr view`, which cannot see the base branch's checks at all.
  // Saying nothing there is the only safe reading: "not marked" must never render as "not yours".
  const quiet = await card({ pullRequest: pullRequest(), fetchedAt: Date.now() / 1000 - 5 });
  const checks = quiet.body.querySelector<HTMLElement>(".acpmux-pr-card__checks")!;
  expect(checks.querySelector(".acpmux-pr-card__sr")?.textContent).toBe("89 of 100 checks passed, 1 failing");
  expect(checks.querySelector(".acpmux-pr-card__onBase")).toBeNull();
  expect(checks.dataset.onBase).toBeUndefined();
  await teardown?.();
  teardown = undefined;
  // And a count that outruns the reds it claims to explain is clamped to them, rather than drawing
  // "1 failing, 7 also red on base".
  const loud = await card({
    pullRequest: pullRequest({ checks: { state: "failing", passed: 99, total: 100, failingOnBase: 7 } }),
    fetchedAt: Date.now() / 1000 - 5,
  });
  expect(loud.body.querySelector(".acpmux-pr-card__checks .acpmux-pr-card__sr")?.textContent).toBe(
    "99 of 100 checks passed, 1 failing, 1 also red on base",
  );
});

test("a host that marks rows without counting them is still read", async () => {
  // The count is the host's own and covers the whole rollup, which is why it wins; the rows are
  // what a host that only marks them leaves, and the card reads those rather than nothing.
  const { body } = await card({
    pullRequest: pullRequest({
      checks: { state: "failing", passed: 98, total: 100 },
      checkList: [
        { name: "cmux-next generated files", state: "failed", onBase: true },
        { name: "web lint (fast)", state: "failed" },
      ],
    }),
    fetchedAt: Date.now() / 1000 - 5,
  });
  expect(body.querySelector(".acpmux-pr-card__checks .acpmux-pr-card__sr")?.textContent).toBe(
    "98 of 100 checks passed, 2 failing, 1 also red on base",
  );
});
