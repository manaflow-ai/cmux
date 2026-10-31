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
): Promise<Record<string, unknown>> {
  const mock = MockAcpmuxSocket.live;
  if (!mock) return { error: "the pane is not on the mock daemon (run the app with --showcase)" };
  acpmuxPerf.enable();
  const started = performance.now();
  const session = mock.seedLoadSession(Math.max(1, Math.floor(turns)));
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
    const blankNow = isBlank(acpmuxPerf.mounted, scroller.scrollTop, scroller.clientHeight, scroller.scrollHeight);
    if (blankNow) blank += 1;
    acpmuxPerf.markFrame(now, blankNow);
    late.push(begin - now);
    work.push((await afterRender()) - now);
    if (streamDone) tail += 1;
  }
  const streamed = await streaming;
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
    layout_ms: stats.layout,
    react_ms: stats.react,
    other_ms: stats.other,
    spans: stats.spans,
    longest,
  };
}
