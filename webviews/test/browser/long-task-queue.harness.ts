// Deterministic long-transcript harness for the periodic snapshot path. The fixture is made once
// as acpmux events and reduced by the real client; each periodic tick only asks the client for a
// snapshot and lets the real turn view consume it. The harness records frame/task numbers without
// walking the transcript itself.
import { turnViewFrom, type TurnView } from "../../src/agent-session/acpmux/conversation/turns";
import { AcpmuxDirectClient, type EventRecord } from "../../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";

const EVENT_COUNT = 192_000;
const TICK_COUNT = 12;
const TICK_MS = 50;
const SESSION_ID = "long-task-queue-fixture";

export type LongTaskQueueReport = {
  eventCount: number;
  rowCount: number;
  ticks: number;
  frames: number;
  tasks: number;
  freshSnapshots: number;
  tickMs: number[];
  maxTickMs: number;
  longTasks: { start: number; duration: number }[];
  tickFrames: number[];
  tickTasks: number[];
  tickRowReads: number[];
};

function fixture(): EventRecord[] {
  return Array.from({ length: EVENT_COUNT }, (_, index) => ({
    sessionId: SESSION_ID,
    seq: index + 1,
    at: 1_791_000_000_000 + index,
    dir: "mux" as const,
    kind: "user_message",
    msg: { promptId: `prompt-${index}`, text: "fixture" },
  }));
}

function run(): Promise<LongTaskQueueReport> {
  const events = fixture();
  let rows: readonly AcpmuxRow[] = [];
  let previousRows: readonly AcpmuxRow[] | undefined;
  let turns: TurnView | undefined;
  const expanded = new Set<string>();
  let frames = 0;
  let tasks = 0;
  const tickMs: number[] = [];
  const tickFrames: number[] = [];
  const tickTasks: number[] = [];
  const tickRowReads: number[] = [];
  let rowReads = 0;
  let freshSnapshots = 0;
  const observedRows = new WeakMap<readonly AcpmuxRow[], readonly AcpmuxRow[]>();
  const observeRows = (source: readonly AcpmuxRow[]): readonly AcpmuxRow[] => {
    const cached = observedRows.get(source);
    if (cached) return cached;
    const proxy = new Proxy(source, {
      get(target, property, receiver) {
        if (typeof property === "string" && /^\d+$/.test(property)) rowReads += 1;
        return Reflect.get(target, property, receiver);
      },
    });
    observedRows.set(source, proxy);
    return proxy;
  };
  const client = AcpmuxDirectClient.replay(SESSION_ID, events, (snapshot) => {
    if (previousRows !== undefined && previousRows !== snapshot.rows) freshSnapshots += 1;
    previousRows = snapshot.rows;
    rows = observeRows(snapshot.rows);
    turns = turnViewFrom(rows, expanded, { now: 1_791_000_000_000 }, turns);
  });
  // Reduce the fixture once before the periodic work begins. The repeated work below is exactly
  // what a metadata heartbeat or other non-transcript snapshot asks the client to do.
  client.seekReplay(EVENT_COUNT);
  rowReads = 0;

  const longTasks: { start: number; duration: number }[] = [];
  const observer =
    typeof PerformanceObserver !== "undefined" && PerformanceObserver.supportedEntryTypes?.includes("longtask")
      ? new PerformanceObserver((list) => {
          for (const entry of list.getEntries())
            longTasks.push({
              start: entry.startTime,
              duration: entry.duration,
            });
        })
      : undefined;
  observer?.observe({ type: "longtask", buffered: false });

  let frameHandle = 0;
  const frameLoop = () => {
    frames += 1;
    frameHandle = requestAnimationFrame(frameLoop);
  };
  frameHandle = requestAnimationFrame(frameLoop);
  let lastTickFrame = frames;
  let lastTickTask = tasks;
  let taskHandle = 0;
  const taskLoop = () => {
    tasks += 1;
    taskHandle = window.setTimeout(taskLoop, 0);
  };
  taskHandle = window.setTimeout(taskLoop, 0);

  return new Promise((resolve) => {
    const timer = window.setInterval(() => {
      const tickStarted = performance.now();
      const readsBefore = rowReads;
      client.snapshot();
      tickFrames.push(frames - lastTickFrame);
      tickTasks.push(tasks - lastTickTask);
      tickRowReads.push(rowReads - readsBefore);
      lastTickFrame = frames;
      lastTickTask = tasks;
      tickMs.push(performance.now() - tickStarted);
      if (tickMs.length < TICK_COUNT) return;
      window.clearInterval(timer);
      cancelAnimationFrame(frameHandle);
      window.clearTimeout(taskHandle);
      // Let the final frame/task observers receive their entries before reading the report.
      window.setTimeout(() => {
        observer?.disconnect();
        resolve({
          eventCount: events.length,
          rowCount: rows.length,
          ticks: tickMs.length,
          frames,
          tasks,
          freshSnapshots,
          tickMs,
          maxTickMs: Math.max(...tickMs),
          longTasks,
          tickFrames,
          tickTasks,
          tickRowReads,
        });
      }, 0);
    }, TICK_MS);
  });
}

declare global {
  interface Window {
    __longTaskQueue: { run: typeof run };
  }
}

window.__longTaskQueue = { run };
