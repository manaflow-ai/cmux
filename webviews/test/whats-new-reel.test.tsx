// l10n-allow-file: test fixtures.
// What's New shows the nightly reel (whats-new lane, 2026-10-20): the nightly publishes a video of
// each build's pull requests (scripts/cmux-next/media/reel.py), but the page never showed it. Now
// the host names a build's reel when one was built (`cmux.changelog.reel`; the mock reads it from
// the fixture's notes). "Since your last update" starts with ONE player (Leo 2026-10-21: not a
// row per nightly): the newest reel as a video card (its first frame, a play button, its length and
// title) that plays in place (Leo 2026-10-21: "this watch is kind aass also id like to be able to
// watch .mp4s direclty in cmux"), and nightly chips pick another. A link opens it only when the
// video cannot play here.
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

test("Since your last update starts with one reel player: the newest reel, and a chip per nightly", async () => {
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
  const players = section?.querySelectorAll(".cl-reel-player") ?? [];
  expect(players.length).toBe(1);
  const player = players[0]!;
  expect(player.querySelectorAll("video").length).toBe(1);
  // Its first frame is the poster: the video shows the frame at 0.1 s before it plays.
  expect(player.querySelector("video")?.getAttribute("src")).toBe(`${video("3940400000000")}#t=0.1`);
  expect(player.querySelector(".cl-reel-title")?.textContent).toBe("What changed in nightly 3940400");
  // It plays here: no link out while the video can play.
  expect(player.querySelector("a.cl-reel")).toBeNull();
  const chips = [...player.querySelectorAll<HTMLButtonElement>("button.cl-reel-chip")];
  expect(chips.map((b) => b.textContent)).toEqual(["nightly 3940400", "nightly 3940200"]);
  expect(chips.map((b) => b.getAttribute("aria-pressed"))).toEqual(["true", "false"]);
  // A chip switches the one player to its nightly's reel.
  await act(async () => chips[1]!.click());
  expect(player.querySelector("video")?.getAttribute("src")).toBe(`${video("3940200000000")}#t=0.1`);
  expect(player.querySelector(".cl-reel-title")?.textContent).toBe("What changed in nightly 3940200");
  expect(player.querySelector('button[aria-pressed="true"]')?.textContent).toBe("nightly 3940200");
  // The player comes before the change list.
  const fold = section?.querySelector(".cl-changes");
  expect(player.compareDocumentPosition(fold!) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
});

test("the card shows the reel's length, and a press plays it in place with controls", async () => {
  const section = await mount([notes("3940400000000", video("3940400000000")), notes("3940100000000")], 1);
  const player = section!.querySelector(".cl-reel-player")!;
  const element = player.querySelector("video")!;
  expect(element.hasAttribute("controls")).toBe(false);
  expect(player.querySelector(".cl-reel-length")).toBeNull();
  // The length comes from the video's metadata, as m:ss.
  Object.defineProperty(element, "duration", { configurable: true, value: 7.5 });
  await act(async () => {
    element.dispatchEvent(new dom.window.Event("loadedmetadata"));
  });
  expect(player.querySelector(".cl-reel-length")?.textContent).toBe("0:08");
  let played = 0;
  element.play = () => {
    played += 1;
    return Promise.resolve();
  };
  const play = player.querySelector<HTMLButtonElement>("button.cl-reel-play")!;
  expect(play.getAttribute("aria-label")).toBe("What changed in nightly 3940400");
  await act(async () => play.click());
  expect(played).toBe(1);
  // Playing, the video's own controls take over: no button over them, no length badge.
  expect(element.hasAttribute("controls")).toBe(true);
  expect(player.querySelector("button.cl-reel-play")).toBeNull();
  expect(player.querySelector(".cl-reel-length")).toBeNull();
  expect(player.querySelector("a.cl-reel")).toBeNull();
});

test("a reel that cannot play here leaves only its link", async () => {
  const section = await mount([notes("3940400000000", video("3940400000000")), notes("3940100000000")], 1);
  const player = section?.querySelector(".cl-reel-player");
  await act(async () => {
    player?.querySelector("video")?.dispatchEvent(new dom.window.Event("error"));
  });
  expect(player?.querySelector("video")).toBeNull();
  expect(player?.querySelector<HTMLAnchorElement>("a.cl-reel")?.href).toBe(video("3940400000000"));
  expect(player?.querySelector("a.cl-reel")?.textContent).toBe("Watch what changed in nightly 3940400");
});

test("a span without a reel shows no card, and a reel that is not an https link is never shown", async () => {
  const section = await mount(
    [notes("3940400000000", "javascript:alert(1)"), notes("3940300000000"), notes("3940100000000")],
    2,
  );
  expect(section?.querySelectorAll(".cl-reel-player, a.cl-reel").length).toBe(0);
});
