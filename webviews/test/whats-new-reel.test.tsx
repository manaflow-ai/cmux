// l10n-allow-file: test fixtures.
// What's New shows the nightly reel (whats-new lane, 2026-10-20): the nightly publishes a video of
// each build's pull requests (scripts/cmux-next/media/reel.py), but the page never showed it. Now
// the host names a build's reel when one was built (`cmux.changelog.reel`; the mock reads it from
// the fixture's notes), and "Since your last update" starts with one card per reel of the span,
// newest first, each a link to the video.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "location", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    url: "cmux-page://cmux.changelog/#/?from=1.0.0-nightly.3940100000000&to=1.0.0-nightly.3940400000000",
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    location: dom.window.location,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const video = (build: string) =>
  `https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/nightly-next/${build}/reel.mp4`;

function notes(build: string, reel?: string) {
  return {
    build,
    shortVersion: `1.0.0-nightly.${build}`,
    date: "2026-10-20",
    highlights: [],
    changes: [`cmux-next sidebar: change of ${build} (#${build.slice(3, 6)})`],
    items: [{ title: `cmux-next sidebar: change of ${build}`, pr: Number(build.slice(3, 6)) }],
    ...(reel ? { reel } : {}),
  };
}

/// Mounts the page and yields until it has asked for the reels of the span's `fresh` builds and
/// every call it made is answered.
async function mount(list: ReturnType<typeof notes>[], fresh: number) {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const { ChangelogOps } = await import("../src/pages/changelog/types");
  let open = 0;
  let reels = 0;
  class Counted extends MockChangelogProvider {
    override async call<R>(op: string, params: unknown): Promise<R> {
      open += 1;
      try {
        return await super.call<R>(op, params);
      } finally {
        open -= 1;
        if (op === ChangelogOps.reel) reels += 1;
      }
    }
  }
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  await act(async () => {
    mountChangelogPage(root, new Counted(list as never, list[0]!.build) as never);
  });
  const deadline = performance.now() + 2_000;
  do {
    if (performance.now() > deadline) throw new Error(`the page asked for ${reels} of ${fresh} reels`);
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  } while (reels < fresh || open > 0);
  return root.querySelector('[data-testid="changelog.sinceLastUpdate"]');
}

test("Since your last update starts with a card for each reel of the span, newest first", async () => {
  const section = await mount(
    [
      notes("3940400000000", video("3940400000000")),
      notes("3940300000000"),
      notes("3940200000000", video("3940200000000")),
      // The installed build's reel is not part of the update.
      notes("3940100000000", video("3940100000000")),
    ],
    3,
  );
  const cards = [...(section?.querySelectorAll<HTMLAnchorElement>("a.cl-reel") ?? [])];
  expect(cards.map((a) => a.href)).toEqual([video("3940400000000"), video("3940200000000")]);
  expect(cards.map((a) => a.textContent)).toEqual([
    "Watch what changed in nightly 3940400",
    "Watch what changed in nightly 3940200",
  ]);
  // The cards come before the change list.
  const fold = section?.querySelector(".cl-changes");
  expect(cards[0]!.compareDocumentPosition(fold!) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
});

test("a span without a reel shows no card, and a reel that is not an https link is never shown", async () => {
  const section = await mount(
    [notes("3940400000000", "javascript:alert(1)"), notes("3940300000000"), notes("3940100000000")],
    2,
  );
  expect(section?.querySelectorAll("a.cl-reel").length).toBe(0);
});
