// l10n-allow-file: test fixtures.
// What's New lists changes by their pull request titles, and hovering one shows nothing (Leo
// 2026-10-19: "I don't want to be able to hover over the various commits and pull request titles
// and have that give a hover preview. It's just strange."). No change title carries a `title` or
// `data-tooltip`, which the pages' tooltip layer (ui/titleTooltips.ts) would show on hover, in the
// Updated card, the Update Ready popover or the changelog page's change list. The #N links still
// open on click.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const titles = [
  "Dictation progress is announced to VoiceOver, with a long title that a narrow sidebar card cuts off",
  "New Tab names its project and machine at once",
];
const data = {
  version: "1.0.0-nightly.3934171000001",
  build: "3934171000001",
  fromVersion: "1.0.0-nightly.3913596493801",
  fromBuild: "3913596493801",
  date: "2026-10-19",
  source: "whatsNew" as const,
  language: "en",
  items: [
    { id: "dictation", title: titles[0]!, summary: "Hears recording.", category: "fixed" as const },
    { id: "new-tab", title: titles[1]!, summary: null, category: "new" as const },
  ],
  moreCount: 4,
  changelog: { from: "1.0.0-nightly.3913596493801", to: "1.0.0-nightly.3934171000001" },
};

async function render(node: (strings: unknown) => ReactNode) {
  const { createRoot } = await import("react-dom/client");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(node(createStrings(table))));
}

/** Every tooltip in the change list `selector` (its rows, titles and links): there should be none.
 * The dismiss x and the popover heading's build tooltip sit outside these lists. */
function titleTooltips(selector: string): string[] {
  return [
    ...host.querySelectorAll(
      `${selector}[title], ${selector}[data-tooltip], ${selector} [title], ${selector} [data-tooltip]`,
    ),
  ].map((el) => el.getAttribute("title") ?? el.getAttribute("data-tooltip") ?? "");
}

const noop = () => undefined;

test("the Updated card's change titles show no hover preview", async () => {
  const { UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
  await render((strings) => (
    <UpdatedCard data={data} strings={strings as never} actions={{ openChangelog: noop, dismiss: noop }} />
  ));
  // The top change (updateSummary.ts's first area) and the rest of the card have no tooltip.
  expect(host.querySelectorAll(".wn-card-note").length).toBe(1);
  expect(titleTooltips(".wn-card")).toEqual([]);
});

test("the Update Ready popover's change titles show no hover preview", async () => {
  const { UpdateReadyHighlights } = await import("../src/pages/changelog/UpdateSurfaces");
  await render((strings) => (
    <UpdateReadyHighlights data={data} strings={strings as never} actions={{ openChangelog: noop, dismiss: noop }} />
  ));
  expect(host.querySelectorAll(".wn-pop-list li").length).toBe(2);
  expect(titleTooltips(".wn-pop-list")).toEqual([]);
});

test("the changelog page's change list shows no hover preview, and its pull request links still open", async () => {
  const { ChangesFold } = await import("../src/pages/changelog/ReleaseParts");
  await render((strings) => (
    <ChangesFold
      open
      strings={strings as never}
      changes={
        [
          { title: titles[0]!, pr: 22001 },
          { title: titles[1]!, pr: 22002 },
        ] as never
      }
    />
  ));
  expect(titleTooltips(".cl-changes ul")).toEqual([]);
  const links = [...host.querySelectorAll<HTMLAnchorElement>(".cl-changes a.cl-pr")].map((a) => a.href);
  expect(links).toEqual([
    "https://github.com/manaflow-ai/cmux/pull/22001",
    "https://github.com/manaflow-ai/cmux/pull/22002",
  ]);
});
