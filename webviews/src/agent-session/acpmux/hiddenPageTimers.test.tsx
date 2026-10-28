// The New Tab page, the run boards and the pull request chip run no timer while the page is hidden
// (MQ4 batch B). Chrome throttles a hidden page's timers
// (third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.cc); a page of
// ours stops them (usePageInterval / startPageInterval, pages/shared/pageLifecycle.ts). A clock
// (the stopwatch, the Now Playing line) reads the time again when the page shows, so its text is
// the one a page that never hid shows; a poll (the run boards, the chip's host ask) makes no read
// on show and waits for its next period.
import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { act, Profiler, type ReactElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NewTabExtras } from "./newtab/NewTabExtras";
import { NowPlayingCard } from "./newtab/NowPlayingPlayer";
import { NewTabScreen } from "./newtab/NewTabScreen";
import { manySessions, noChat } from "../../gallery/fixtures/acpmux";
import type { NowPlayingTrack } from "./newtab/nowPlaying";
import { resetPullRequestStore, usePullRequestAnswer } from "./chips/pullRequestStore";
import { setChipHost } from "./chips/host";
import { RunBoard } from "./run-board/RunBoard";
import { CompareRunBoard } from "./run-board/variants/compare/CompareRunBoard";
import { TimelineRunBoard } from "./run-board/variants/timeline/TimelineRunBoard";
import { replayedBoardFixture, runBoardFixture } from "./run-board/fixtures";
import type { RunApiClient } from "./run-board/runApi";

let dom: JSDOM | undefined;
let root: Root | undefined;
let visibility: DocumentVisibilityState = "visible";
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const MINUTE = 60_000;

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
  Object.defineProperty(dom.window.document, "hidden", { configurable: true, get: () => visibility === "hidden" });
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(globals)) saved.set(key, scope[key]);
  Object.assign(scope, globals);
  return dom.window.document.getElementById("root")!;
}

beforeEach(() => {
  visibility = "visible";
  jest.useFakeTimers();
  jest.setSystemTime(1_000_000);
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  jest.useRealTimers();
  setChipHost(undefined);
  resetPullRequestStore();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function mount(element: ReactElement): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(element);
  });
  return container;
}

async function advance(ms: number) {
  await act(async () => {
    jest.advanceTimersByTime(ms);
  });
}

async function setVisibility(next: DocumentVisibilityState) {
  visibility = next;
  await act(async () => {
    document.dispatchEvent(new dom!.window.Event("visibilitychange"));
  });
}

test("the New Tab stopwatch rests while hidden and shows the true time again on show", async () => {
  const page = await mount(<NewTabExtras widgets={new Set(["timer"])} now={Date.now()} />);
  const timer = () => page.querySelector(".nt-extra-timer")?.textContent?.replace(/\s+/g, " ");
  await advance(3_000);
  expect(timer()).toContain("0:03");

  await setVisibility("hidden");
  expect(jest.getTimerCount()).toBe(0);
  await advance(MINUTE);
  expect(timer()).toContain("0:03");

  await setVisibility("visible");
  expect(timer()).toContain("1:03");
  await advance(1_000);
  expect(timer()).toContain("1:04");
});

const playing: NowPlayingTrack = {
  title: "Song",
  artist: "Band",
  playing: true,
  position: 0,
  duration: 200,
  rate: 1,
  positionDate: 1_000_000,
  canPrevious: true,
  canNext: true,
  labels: { play: "Play", pause: "Pause", previous: "Previous", next: "Next" },
};

test("the Now Playing line rests while hidden and reads the time again on show", async () => {
  const page = await mount(<NowPlayingCard track={playing} onCommand={() => {}} />);
  const width = () => parseFloat((page.querySelector(".nt-player-played") as HTMLElement | null)?.style.width ?? "");
  await advance(10_000);
  expect(width()).toBe(5);

  await setVisibility("hidden");
  expect(jest.getTimerCount()).toBe(0);
  await advance(MINUTE);
  expect(width()).toBe(5);

  await setVisibility("visible");
  expect(width()).toBe(35);
});

function PullRequestProbe({ url }: { url: string }) {
  const answer = usePullRequestAnswer(url, true);
  return <output>{answer?.reading ? "reading" : "settled"}</output>;
}

test("the pull request chip asks the host nothing while hidden and makes no ask on show", async () => {
  let asks = 0;
  setChipHost(async () => {
    asks += 1;
    return { pullRequest: null, reading: true, fetchedAt: asks };
  });
  await mount(<PullRequestProbe url="https://github.com/o/r/pull/1" />);
  expect(asks).toBe(1);
  await advance(1_500);
  expect(asks).toBe(2);

  await setVisibility("hidden");
  expect(jest.getTimerCount()).toBe(0);
  await advance(MINUTE);
  expect(asks).toBe(2);

  await setVisibility("visible");
  expect(asks).toBe(2);
  await advance(1_500);
  expect(asks).toBe(3);
});

function countingClient(): { client: RunApiClient; reads: () => number } {
  let reads = 0;
  return {
    client: {
      getSnapshot: async () => runBoardFixture,
      getEvents: async () => {
        reads += 1;
        return { events: [] };
      },
    },
    reads: () => reads,
  };
}

const boards = [
  [
    "RunBoard",
    (client: RunApiClient) => (
      <RunBoard snapshot={runBoardFixture} recovered={replayedBoardFixture} client={client} pollMs={4_000} />
    ),
  ],
  [
    "CompareRunBoard",
    (client: RunApiClient) => (
      <CompareRunBoard snapshot={runBoardFixture} recovered={replayedBoardFixture} client={client} pollMs={4_000} />
    ),
  ],
  [
    "TimelineRunBoard",
    (client: RunApiClient) => (
      <TimelineRunBoard snapshot={runBoardFixture} recovered={replayedBoardFixture} client={client} pollMs={4_000} />
    ),
  ],
] as const;

for (const [name, board] of boards)
  test(`${name} polls nothing while hidden and reads nothing on show`, async () => {
    const { client, reads } = countingClient();
    await mount(board(client));
    const atMount = reads();
    await advance(4_000);
    expect(reads()).toBe(atMount + 1);

    await setVisibility("hidden");
    expect(jest.getTimerCount()).toBe(0);
    await advance(MINUTE);
    expect(reads()).toBe(atMount + 1);

    await setVisibility("visible");
    expect(reads()).toBe(atMount + 1);
    await advance(4_000);
    expect(reads()).toBe(atMount + 2);
  });

const newTabActions = {
  onAsk: () => {},
  onOpen: () => {},
  onSearch: () => {},
  onShell: () => {},
  onJump: () => {},
  onOpenSession: () => {},
  onShowAll: () => {},
};

// The New Tab page re-renders only through its own timers here: the snapshot and props never change.
const newTabSnapshot = noChat(manySessions(3));
function CountedNewTab({ onCommit }: { onCommit: () => void }) {
  return (
    <Profiler id="new-tab" onRender={onCommit}>
      <NewTabScreen snapshot={newTabSnapshot} {...newTabActions} />
    </Profiler>
  );
}

test("a hidden New Tab page arms no timer and makes 0 callbacks in 60 s", async () => {
  visibility = "hidden";
  let commits = 0;
  await mount(<CountedNewTab onCommit={() => (commits += 1)} />);
  // The field's focus at mount queues JSDOM's own `select` event tasks (0 ms); none is the page's.
  await advance(0);
  const atMount = commits;
  expect(jest.getTimerCount()).toBe(0);
  await advance(MINUTE);
  expect(commits).toBe(atMount);
  expect(jest.getTimerCount()).toBe(0);

  // Shown, the shared minute clock arms again; it reads the time, never data.
  await setVisibility("visible");
  expect(jest.getTimerCount()).toBeGreaterThan(0);
});

test("the New Tab page's minute clock stops when the page hides and reads the minute again on show", async () => {
  let commits = 0;
  await mount(<CountedNewTab onCommit={() => (commits += 1)} />);
  const atMount = commits;
  await advance(MINUTE);
  expect(commits).toBeGreaterThan(atMount);

  await setVisibility("hidden");
  expect(jest.getTimerCount()).toBe(0);
  const atHide = commits;
  await advance(3 * MINUTE);
  expect(commits).toBe(atHide);

  // The minute changed while hidden: the page draws it once on show, as a page that never hid.
  await setVisibility("visible");
  expect(commits).toBe(atHide + 1);
  expect(jest.getTimerCount()).toBeGreaterThan(0);
});
