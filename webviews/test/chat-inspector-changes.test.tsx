// l10n-allow-file: test fixture pull request titles, not shipped UI.
// The Inspector's Changes rows, after Claude Code desktop's (Leo 2026-10-21: "WHY WOULD IT SHOW
// 'MERGED' IF WE ALREADY KNOW IT'S MERGED?"): the title, then `repo #N`, the line counts, the
// comments and the failing checks; the state is the glyph's shape and color, never a word. Open
// ones come first, then the merged and closed; five show, then Show more / Show less. A row's
// click opens it beside the chat.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import {
  CHANGES_SHOWN,
  ChangesSection,
  changesOrder,
  glyphState,
  visibleChanges,
  type InspectorPullRequestStatus,
} from "../src/agent-session/acpmux/inspector/ChangesSection";
import type { SummaryPullRequest } from "../src/agent-session/acpmux/summary/sessionSummary";
import { transcriptPullRequests } from "../src/agent-session/acpmux/summary/transcriptPullRequests";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const pr = (repo: string, number: number, state: SummaryPullRequest["state"] = "open"): SummaryPullRequest => ({
  url: `https://github.com/${repo}/pull/${number}`,
  repo,
  number,
  state,
  opened: true,
});

async function render(
  container: HTMLElement,
  pullRequests: readonly SummaryPullRequest[],
  statuses: Record<string, InspectorPullRequestStatus> = {},
  onOpenBeside?: (url: string) => void,
) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<ChangesSection pullRequests={pullRequests} statuses={statuses} onOpenBeside={onOpenBeside} />);
  });
}

const rows = (container: HTMLElement) => [...container.querySelectorAll<HTMLElement>("li.acpmux-chat-inspector-pr")];
const refs = (container: HTMLElement) =>
  rows(container).map((row) => row.querySelector(".acpmux-chat-inspector-pr__ref")?.textContent);
const fold = (container: HTMLElement) =>
  container.querySelector<HTMLButtonElement>("button.acpmux-chat-inspector-pr-fold");

test("each state is the glyph's shape and the row's color, and no row says Merged or Closed", async () => {
  const container = installDom();
  const merged = pr("manaflow-ai/cmux", 23377, "merged");
  const closed = pr("manaflow-ai/glaeda", 1546, "closed");
  const draft = pr("teamleaderleo/leo-workspace", 636);
  const conflicting = pr("manaflow-ai/cmux", 20560);
  const open = pr("manaflow-ai/cmuxterm-hq", 2681);
  // Oldest first: the ended ones are the newest, and still go last.
  await render(container, [draft, conflicting, open, closed, merged], {
    [draft.url]: { state: "draft" },
    [conflicting.url]: { state: "open", mergeable: "conflicting" },
    [open.url]: { state: "open", mergeable: "mergeable" },
  });
  const states = rows(container).map((row) => [
    row.querySelector(".acpmux-chat-inspector-pr__ref")?.textContent,
    row.dataset.state,
    row.querySelector("svg.acpmux-chat-inspector-pr__glyph")?.getAttribute("data-glyph"),
  ]);
  expect(states).toEqual([
    ["cmuxterm-hq #2681", "open", "open"],
    ["cmux #20560", "conflicting", "conflicting"],
    ["leo-workspace #636", "draft", "draft"],
    ["cmux #23377", "merged", "merged"],
    ["glaeda #1546", "closed", "closed"],
  ]);
  // The words are for screen readers only, inside the glyph's label; the line shows none.
  for (const row of rows(container)) {
    const line = row.querySelector(".acpmux-chat-inspector-pr__line")!.textContent ?? "";
    expect(line).not.toMatch(/Merged|Closed|Open|Draft|conflicts/);
  }
  expect(container.querySelector(".acpmux-chat-inspector-pr__state")).toBeNull();
  expect(rows(container)[3]!.querySelector(".acpmux-chat-inspector-sr-only")?.textContent).toBe("Merged");
});

test("the title leads, then repo #N, the line counts, the comments, and the failing checks or a green dot", async () => {
  const container = installDom();
  const failing = pr("manaflow-ai/cmux", 22033);
  const green = pr("manaflow-ai/cmux-app-screenshots", 62);
  const unknown = pr("manaflow-ai/cmux", 22523);
  await render(container, [unknown, green, failing], {
    [failing.url]: {
      title: "cmux-next: backgrounds batch",
      additions: 758,
      deletions: 265,
      comments: 13,
      checks: "failing",
      failing: 11,
    },
    [green.url]: { title: "README: point design references", checks: "passing", comments: 0 },
  });
  const [first, second, third] = rows(container);
  expect(first!.querySelector(".acpmux-chat-inspector-pr__title")?.textContent).toBe("cmux-next: backgrounds batch");
  const line = first!.querySelector(".acpmux-chat-inspector-pr__line")!;
  expect([...line.children].map((child) => child.className)).toEqual([
    "acpmux-chat-inspector-pr__ref",
    "acpmux-diff-counts",
    "acpmux-chat-inspector-pr__comments",
    "acpmux-chat-inspector-pr__checks",
  ]);
  expect(line.querySelector(".acpmux-chat-inspector-pr__comments")?.textContent).toBe("13Comments: 13");
  expect(line.querySelector(".acpmux-chat-inspector-pr__checks")?.textContent).toBe("11 failing");
  // Green checks: a dot with no text, and no comment count at zero.
  expect(second!.querySelector(".acpmux-chat-inspector-pr__comments")).toBeNull();
  expect(second!.querySelector('.acpmux-chat-inspector-pr__checks[data-checks="passing"]')).not.toBeNull();
  // Nothing read yet: its number stands in for the title, and the end of the line is empty.
  expect(third!.querySelector(".acpmux-chat-inspector-pr__title")?.textContent).toBe("#22523");
  expect(third!.querySelector(".acpmux-chat-inspector-pr__checks")).toBeNull();
});

test("five rows show, then Show more opens the rest and Show less folds them again", async () => {
  const container = installDom();
  const all = Array.from({ length: 8 }, (_, index) => pr("manaflow-ai/cmux", 100 + index));
  await render(container, all);
  expect(rows(container)).toHaveLength(CHANGES_SHOWN);
  expect(refs(container)[0]).toBe("cmux #107");
  expect(fold(container)?.textContent).toBe("Show more");
  expect(fold(container)?.getAttribute("aria-expanded")).toBe("false");
  await act(async () => fold(container)!.click());
  expect(rows(container)).toHaveLength(8);
  expect(fold(container)?.textContent).toBe("Show less");
  await act(async () => fold(container)!.click());
  expect(rows(container)).toHaveLength(CHANGES_SHOWN);

  // Five or fewer: no fold at all.
  await render(container, all.slice(0, CHANGES_SHOWN));
  expect(fold(container)).toBeNull();
});

test("a row's click opens its pull request beside the chat", async () => {
  const container = installDom();
  const opened: string[] = [];
  const one = pr("manaflow-ai/cmux", 22377);
  await render(container, [one], {}, (url) => opened.push(url));
  const link = container.querySelector<HTMLAnchorElement>("a.acpmux-chat-inspector-pr__link")!;
  const event = new dom!.window.MouseEvent("click", { bubbles: true, cancelable: true });
  await act(async () => void link.dispatchEvent(event));
  expect(opened).toEqual([one.url]);
  expect(event.defaultPrevented).toBe(true);
});

test("the whole lit row is one target: its owner chip opens the pull request, and the link covers the row", async () => {
  const container = installDom();
  const opened: string[] = [];
  const one = pr("manaflow-ai/cmux", 22377);
  await render(container, [one], { [one.url]: { owner: "inspector" } }, (url) => opened.push(url));
  const click = async (element: Element) => {
    const event = new dom!.window.MouseEvent("click", { bubbles: true, cancelable: true });
    await act(async () => void element.dispatchEvent(event));
    return event;
  };
  // The owner chip is a label inside the row's link, not a dead control of its own.
  const chip = container.querySelector(".acpmux-chat-inspector-pr__owner")!;
  expect(chip.closest("a.acpmux-chat-inspector-pr__link")).not.toBeNull();
  await click(chip);
  expect(opened).toEqual([one.url]);
  // The ⋯ button is still its own target: it opens the menu, not the pull request.
  await click(container.querySelector("button.acpmux-chat-inspector-pr__more")!);
  expect(opened).toEqual([one.url]);
  // The row's own padding and gap light on hover too, so the link's hit area covers the whole row
  // (JSDOM lays nothing out, so this reads the rule that does it), with the ⋯ button above it.
  const css = readFileSync(new URL("../src/agent-session/acpmux/inspector/inspector.css", import.meta.url), "utf8");
  expect(css).toMatch(/\.acpmux-chat-inspector-pr \{\s*position: relative;/);
  expect(css).toMatch(/\.acpmux-chat-inspector-pr__link::before \{[^}]*position: absolute;[^}]*inset: 0;/);
  expect(css).toMatch(/\.acpmux-chat-inspector-pr__more \{\s*position: relative;/);
  // The link's own content stays above that overlay, so its tooltips (the state glyph's and the
  // check dot's titles, the line counts' by-kind breakdown) still get the pointer.
  expect(css).toMatch(/\.acpmux-chat-inspector-pr__link > \* \{\s*position: relative;/);
});

test("open ones come first, the most recently touched first, then the merged and closed", () => {
  // A merged and a closed one newer than the open ones still go after them.
  const list = [pr("a/x", 1), pr("a/x", 2, "merged"), pr("a/x", 3), pr("a/x", 4, "closed"), pr("a/x", 5)];
  const order = changesOrder(list, { [list[4]!.url]: { state: "merged" } }).map((item) => item.number);
  // #5 the App reads as merged since: it goes with the ended ones, newest first.
  expect(order).toEqual([3, 1, 5, 4, 2]);
  // Where the chat last touched or named each one decides, not where it first did.
  const touched = [
    { ...pr("a/x", 1), touched: 9 },
    { ...pr("a/x", 2), touched: 2 },
    { ...pr("a/x", 3, "merged"), touched: 1 },
    { ...pr("a/x", 4, "merged"), touched: 5 },
  ];
  expect(changesOrder(touched, {}).map((item) => item.number)).toEqual([1, 2, 4, 3]);
  expect(glyphState(pr("a/x", 5), { mergeable: "conflicting" })).toBe("conflicting");
  expect(glyphState(pr("a/x", 6, "merged"), { mergeable: "conflicting" })).toBe("merged");
});

test("visible Changes excludes read-only PR references", () => {
  const created = { ...pr("a/x", 1), changed: true };
  const inspected = transcriptPullRequests([
    {
      id: "read-only",
      version: 1,
      at: 1,
      kind: "activity",
      items: [
        {
          tool: {
            id: "view",
            kind: "execute",
            status: "completed",
            exitCode: 0,
            title: "gh pr view",
            command: "gh pr view 2 -R a/x",
            output: "",
          },
        },
      ],
    },
  ] as never)[0]!;
  const edited = { ...pr("a/x", 3), opened: false, changed: true };
  const mutatedIssue = {
    url: "https://github.com/a/x/issues/4",
    repo: "a/x",
    number: 4,
    kind: "issue" as const,
    opened: false,
    changed: true,
    state: "open" as const,
  };
  expect(visibleChanges([created, inspected, edited, mutatedIssue], {})).toEqual([created, edited]);
});
