import { userScrollIntent } from "./conversation/userScroll";
// `debug.agent_pane load_seed` and `load_run`: the chat under load, through the real client.
// load_seed records a session of thousands of heavy turns (loadFixture.ts) in the mock daemon
// and opens it, so the whole transcript comes in through attach, the reducer and the snapshot
// path as a real agent's does. load_run then streams a turn at full speed while it scrolls the
// transcript up into the history and back, and reports every frame.
//
// A frame's work is the time from its start (the rAF timestamp) until the page has rendered it
// (a message posted from the frame runs after the rendering update), so a frame that misses a
// 120 Hz display needs more than 8.33 ms however fast the display under the run is.
import { MockAcpmuxSocket } from "./mock";
import { acpmuxPerf, frameStats, isBlank, median, percentile, round2 } from "./perf";

export type LoadRunOptions = {
  seconds?: number;
  /// Characters in each text delta, milliseconds between deltas, and deltas between large tool calls.
  chunk_chars?: number;
  chunk_ms?: number;
  tool_every?: number;
  /// Scroll speed in points per second; 0 streams without scrolling.
  scroll_speed?: number;
  /// How far up the scroll goes before it turns back, in viewports.
  scroll_depth?: number;
};

const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
const BUDGET_120 = 1000 / 120;

/// When the page has rendered the current frame: a posted message runs after the rendering update.
function afterRender(): Promise<number> {
  return new Promise((resolve) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => {
      channel.port1.close();
      resolve(performance.now());
    };
    channel.port2.postMessage(0);
  });
}

export async function loadSeed(
  host: { selectSession(sessionId: string): void; rowCount(): number },
  turns: number,
  options: { light?: boolean } = {},
): Promise<Record<string, unknown>> {
  const mock = MockAcpmuxSocket.live;
  if (!mock) return { error: "the pane is not on the mock daemon (run the app with --showcase)" };
  acpmuxPerf.enable();
  const started = performance.now();
  const session = mock.seedLoadSession(Math.max(1, Math.floor(turns)), options.light === true);
  const seeded = performance.now();
  host.selectSession(session);
  // The transcript is in once its row count stops growing. Each frame also reads what is on
  // screen: the first frame with transcript text in view (time to first content), whether that
  // frame was at the latest message, and every later frame whose rows in view moved (a shift).
  let last = -1;
  let still = 0;
  let firstContent: number | undefined;
  let firstAtLatest: boolean | undefined;
  let shifts = 0;
  let shown: string | undefined;
  const deadline = performance.now() + 25_000;
  while (still < 20 && performance.now() < deadline) {
    await frame();
    const now = await afterRender();
    const count = host.rowCount();
    still = count === last && count > 0 ? still + 1 : 0;
    last = count;
    const view = inView();
    if (!view) continue;
    if (firstContent === undefined) {
      firstContent = now - seeded;
      firstAtLatest = view.atLatest;
    } else if (view.key !== shown) shifts += 1;
    shown = view.key;
  }
  return {
    session,
    turns,
    rows: host.rowCount(),
    seed_ms: round2(seeded - started),
    first_content_ms: firstContent === undefined ? null : round2(firstContent),
    first_content_at_latest: firstAtLatest ?? null,
    shifts_after_first_content: shifts,
    open_ms: round2(performance.now() - seeded),
  };
}

/// The transcript rows in view, by id and place (a key that changes when any of them moves), and
/// whether the view is at its latest message; undefined while no row with text is in view.
function inView(): { key: string; atLatest: boolean } | undefined {
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return undefined;
  const box = scroller.getBoundingClientRect();
  const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].filter((row) => {
    const rect = row.getBoundingClientRect();
    return rect.bottom > box.top && rect.top < box.bottom && rect.width > 0 && (row.textContent ?? "").trim() !== "";
  });
  if (!rows.length) return undefined;
  const opacity = Number(getComputedStyle(scroller).opacity);
  if (opacity === 0) return undefined;
  const key = rows
    .map((row) => `${row.dataset.rowId ?? row.id}@${Math.round(row.getBoundingClientRect().top - box.top)}`)
    .join(",");
  return { key, atLatest: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop <= 2 };
}

export async function loadRun(
  host: { sessionId(): string | undefined; rowCount(): number },
  options: LoadRunOptions = {},
): Promise<Record<string, unknown>> {
  const mock = MockAcpmuxSocket.live;
  const session = host.sessionId();
  if (!mock || !session) return { error: "no load session (run load_seed first)" };
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return { error: "no transcript" };
  acpmuxPerf.enable();
  const seconds = Math.max(1, options.seconds ?? 8);
  const speed = Math.max(0, options.scroll_speed ?? 3000);
  const depth = Math.max(0.5, options.scroll_depth ?? 40);
  const requested = userScrollIntent(scroller).request();
  scroller.scrollTop = scroller.scrollHeight;
  const warmup: number[] = [];
  for (let index = 0; index < 30; index += 1) warmup.push(await frame());
  // A page still busy from the seed stretches the warmup frames; no display here is slower than 60 Hz.
  const nominal = Math.min(1000 / 60, Math.max(1, median(warmup.slice(1).map((time, index) => time - warmup[index]!))));
  acpmuxPerf.resetFrames();
  acpmuxPerf.resetRenders();
  const streaming = mock.streamLoadTurn(session, {
    seconds,
    chunkChars: Math.max(1, Math.floor(options.chunk_chars ?? 32)),
    chunkMs: Math.max(1, options.chunk_ms ?? 4),
    toolEvery: Math.max(0, Math.floor(options.tool_every ?? 60)),
  });
  let streamDone = false;
  void streaming.then(() => (streamDone = true));
  const timestamps: number[] = [];
  const work: number[] = [];
  const late: number[] = [];
  let blank = 0;
  let liveLineHidden = 0;
  // The scroll: up from the bottom at `speed` until `depth` viewports above it, then back down to
  // the bottom, again and again, while the reply streams in below.
  const span = depth * scroller.clientHeight;
  let offset = 0;
  let direction = speed > 0 ? 1 : 0;
  let previous: number | undefined;
  let tail = 0;
  while (tail < 30) {
    const now = await frame();
    const begin = performance.now();
    timestamps.push(now);
    if (previous !== undefined && direction !== 0) {
      offset += (direction * speed * (now - previous)) / 1000;
      if (offset >= span) {
        offset = span;
        direction = -1;
      } else if (offset <= 0) {
        offset = 0;
        direction = 1;
      }
    }
    previous = now;
    if (!streamDone && requested()) scroller.scrollTop = scroller.scrollHeight - scroller.clientHeight - offset;
    // The live line under a reply whose text streams stays shown, reading "Writing" (Thinking.tsx
    // `quietKey`): it never leaves and comes back mid-turn.
    if (!streamDone && document.querySelector(".cv-worked--live.is-quiet")) liveLineHidden += 1;
    const blankNow = isBlank(acpmuxPerf.mounted, scroller.scrollTop, scroller.clientHeight, scroller.scrollHeight);
    if (blankNow) blank += 1;
    acpmuxPerf.markFrame(now, blankNow);
    late.push(begin - now);
    work.push((await afterRender()) - now);
    if (streamDone) tail += 1;
  }
  const streamed = await streaming;
  // Renders per component over the run (`acpmuxPerf.render`): the pane root, the composer and
  // each row by id (`row:<id>`), so a caller can tell what a streamed chunk re-rendered.
  const renders = Object.fromEntries(acpmuxPerf.renders);
  const sorted = [...work].sort((a, b) => a - b);
  const stats = acpmuxPerf.stats(false) as Record<string, unknown>;
  // The longest frames, in order, with what they spent where.
  const samples = acpmuxPerf.stats(true).samples as Record<string, unknown>[];
  const longest = work
    .map((ms, index) => ({ index, work_ms: round2(ms), ...samples[index - 1] }))
    .sort((a, b) => b.work_ms - a.work_ms)
    .slice(0, 12);
  return {
    rows: host.rowCount(),
    ...streamed,
    seconds,
    scroll_speed: speed,
    display: frameStats(timestamps, nominal),
    work_ms: {
      p50: round2(percentile(sorted, 0.5)),
      p95: round2(percentile(sorted, 0.95)),
      p99: round2(percentile(sorted, 0.99)),
      max: round2(sorted.at(-1) ?? 0),
    },
    late_start_ms: {
      p95: round2(
        percentile(
          [...late].sort((a, b) => a - b),
          0.95,
        ),
      ),
    },
    over_120hz_budget: sorted.filter((ms) => ms > BUDGET_120).length,
    over_60hz_budget: sorted.filter((ms) => ms > 1000 / 60).length,
    frames: work.length,
    blank_frames: blank,
    live_line_hidden_frames: liveLineHidden,
    layout_ms: stats.layout,
    react_ms: stats.react,
    other_ms: stats.other,
    spans: stats.spans,
    renders,
    longest,
  };
}

export type LoadTickOptions = {
  seconds?: number;
  /// Milliseconds between the running command's output updates.
  tick_ms?: number;
  /// Milliseconds between changes to another chat in the list (0: none).
  sidebar_ms?: number;
  /// Scroll speed in points per second, and how far up it goes before it turns back, in viewports.
  scroll_speed?: number;
  scroll_depth?: number;
  /// What scrolls: the transcript (`chat`, the default) or Session Info's own body (`session-info`).
  scroll_target?: "chat" | "session-info";
  /// Text each output line ends with (` see #12`: a `#N` the pane reads out of the output, so each
  /// update draws through the pane, liveToolOutput.ts).
  line_suffix?: string;
};

/// The Session Info parts counted while `loadTick` runs (SessionInfo.tsx `useCountedRender`): its
/// presence (placement and lists), its panel frame and its memoized sections.
const SESSION_INFO_PARTS = ["presence", "panel", "sections"] as const;

/// `debug.agent_pane load_tick`: the reader scrolls up into the history and back while one tool call
/// runs (its output and the live line tick) and another chat in the list changes, with no reply text.
/// A history row's content never changes over the run, so each of its renders past its mount is
/// waste, and a remount (unmounted and mounted in one commit) redraws it from nothing: what the
/// reader sees as a flicker. Reports both per second, with the busiest history rows.
///
/// With Session Info shown it counts the panel's committed renders and its DOM mutations over the
/// run too: a scroll changes nothing the panel shows, so a frame that draws it again is waste.
/// `tick_ms: 0` runs no tool call and changes no chat (the scroll alone, for `seconds`), and
/// `scroll_target: "session-info"` scrolls the panel's body instead of the transcript.
export async function loadTick(
  host: { sessionId(): string | undefined; rowIds(): string[] },
  options: LoadTickOptions = {},
): Promise<Record<string, unknown>> {
  const mock = MockAcpmuxSocket.live;
  const session = host.sessionId();
  if (!mock || !session) return { error: "no load session (run load_seed first)" };
  const transcript = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!transcript) return { error: "no transcript" };
  const panel = document.querySelector<HTMLElement>("aside.acpmux-session-info");
  const panelTarget = options.scroll_target === "session-info";
  const scroller = panelTarget ? panel?.querySelector<HTMLElement>(".acpmux-session-info__body") : transcript;
  if (!scroller) return { error: "no Session Info body to scroll" };
  if (panelTarget && scroller.scrollHeight <= scroller.clientHeight)
    return { error: "Session Info's body does not scroll (open more sections)" };
  acpmuxPerf.enable();
  const seconds = Math.max(1, options.seconds ?? 6);
  const speed = Math.max(0, options.scroll_speed ?? 2400);
  const depth = Math.max(0.5, options.scroll_depth ?? 12);
  const initial = new Set(host.rowIds());
  const requested = panelTarget ? () => true : userScrollIntent(scroller).request();
  scroller.scrollTop = scroller.scrollHeight;
  for (let index = 0; index < 30; index += 1) await frame();
  acpmuxPerf.resetRenders();
  // DOM changes in the panel over the run, and how many of them were the scroll mark (scrollers.ts
  // `data-cmux-scrolling`), which a scroll of the panel's own body sets.
  let mutations = 0;
  let scrollMarks = 0;
  const watch = new MutationObserver((records) => {
    mutations += records.length;
    for (const record of records) if (record.attributeName === "data-cmux-scrolling") scrollMarks += 1;
  });
  if (panel) watch.observe(panel, { subtree: true, childList: true, attributes: true, characterData: true });
  const started = performance.now();
  const tickMs = options.tick_ms ?? 100;
  const ticking =
    tickMs > 0
      ? mock.tickLoadTurn(session, {
          seconds,
          tickMs: Math.max(16, tickMs),
          sidebarMs: Math.max(0, options.sidebar_ms ?? 250),
          lineSuffix: options.line_suffix ?? "",
        })
      : new Promise<{ ticks: number; sidebar: number }>((resolve) =>
          setTimeout(() => resolve({ ticks: 0, sidebar: 0 }), seconds * 1000),
        );
  let done = false;
  void ticking.then(() => (done = true));
  // The panel's body scrolls its whole height and back; the transcript `depth` viewports.
  const span = panelTarget ? scroller.scrollHeight - scroller.clientHeight : depth * scroller.clientHeight;
  let offset = 0;
  let direction = speed > 0 ? 1 : 0;
  let previous: number | undefined;
  let frames = 0;
  while (!done) {
    const now = await frame();
    frames += 1;
    if (previous !== undefined && direction !== 0) {
      offset += (direction * speed * (now - previous)) / 1000;
      if (offset >= span) {
        offset = span;
        direction = -1;
      } else if (offset <= 0) {
        offset = 0;
        direction = 1;
      }
    }
    previous = now;
    if (requested()) scroller.scrollTop = scroller.scrollHeight - scroller.clientHeight - offset;
  }
  const elapsed = (performance.now() - started) / 1000;
  const ticked = await ticking;
  for (const record of watch.takeRecords()) {
    mutations += 1;
    if (record.attributeName === "data-cmux-scrolling") scrollMarks += 1;
  }
  watch.disconnect();
  const sessionInfo = panel
    ? {
        ...Object.fromEntries(
          SESSION_INFO_PARTS.map((part) => [part, acpmuxPerf.renders.get(`session-info:${part}`) ?? 0]),
        ),
        mutations,
        scroll_marks: scrollMarks,
      }
    : undefined;
  const count = (prefix: string, only?: Set<string>) => {
    let total = 0;
    const byRow = new Map<string, number>();
    for (const [name, value] of acpmuxPerf.renders) {
      if (!name.startsWith(prefix)) continue;
      const id = name.slice(prefix.length);
      if (only && !only.has(id)) continue;
      total += value;
      byRow.set(id, value);
    }
    return { total, byRow };
  };
  // The history is every row up to the last one shown before the run, in the order at its end: the
  // rows it started with and any older page the scroll loaded; the rest is the running turn.
  const ids = host.rowIds();
  let last = -1;
  ids.forEach((id, index) => {
    if (initial.has(id)) last = index;
  });
  const history = new Set(ids.slice(0, last + 1));
  const frameRenders = count("frame:", history);
  const contents = count("content:", history);
  const mounts = count("mount:", history);
  const remounts = count("remount:");
  const past = (renders: { byRow: Map<string, number> }) =>
    [...renders.byRow].map(([id, value]) => [id, Math.max(0, value - (mounts.byRow.get(id) ?? 0))] as const);
  const sum = (rows: readonly (readonly [string, number])[]) => rows.reduce((total, [, value]) => total + value, 0);
  const frameRedraws = past(frameRenders);
  const contentRedraws = past(contents);
  const perSecond = (value: number) => round2(value / elapsed);
  return {
    ...ticked,
    // Renders per component over the run (`acpmuxPerf.render`), as `loadRun` reports them.
    renders: Object.fromEntries(acpmuxPerf.renders),
    seconds: round2(elapsed),
    frames,
    scroll_target: panelTarget ? "session-info" : "chat",
    scrolled_px: Math.round(span),
    session_info: sessionInfo,
    history_rows: history.size,
    history_mounts: mounts.total,
    history_mounts_per_s: perSecond(mounts.total),
    // A frame drawn again (its place, focus or flags) past its mount, and its content drawn again.
    frame_rerenders: sum(frameRedraws),
    frame_rerenders_per_s: perSecond(sum(frameRedraws)),
    content_rerenders: sum(contentRedraws),
    content_rerenders_per_s: perSecond(sum(contentRedraws)),
    remounts: remounts.total,
    remounted: [...remounts.byRow.keys()],
    busiest: contentRedraws
      .filter(([, value]) => value > 0)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 8),
  };
}
