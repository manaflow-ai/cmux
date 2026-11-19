// l10n-allow-file: benchmark output, not shipped UI.
// Every task the page's main thread ran in a window, from a light Chromium trace (`toplevel` only: one RunTask event
// per task, so the tracing itself costs little). The longtask observer reports only tasks of 50 ms or more; this
// reads them all, so a bench can say how long the longest task was when none reached 50 ms, and how many passed the
// 2, 4 and 8 ms marks of the agent pane's scheduler (schedule/lanes.ts: slices of SLICE_MS, a frame of 8.3 ms at
// 120 Hz). composer-typing.bench.ts --tasks.
import type { Browser, Page } from "playwright";

type Ev = { name: string; ph: string; ts: number; dur?: number; tid: number; pid: number; args?: any };

export type MainTaskStats = {
  main_tasks: number;
  main_task_max_ms: number;
  main_task_p99_ms: number;
  main_tasks_over_2ms: number;
  main_tasks_over_4ms: number;
  main_tasks_over_8ms: number;
};

const TASK_NAMES = new Set(["ThreadControllerImpl::RunTask", "RunTask"]);

/** Runs `run` under a `toplevel` trace of `page`'s renderer and returns its main thread's task durations, ms. */
export async function traceMainTasks(browser: Browser, page: Page, run: () => Promise<unknown>): Promise<number[]> {
  await browser.startTracing(page, { categories: ["toplevel", "__metadata"] });
  await run();
  const raw = JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: Ev[] };
  const events = raw.traceEvents;
  const mains = new Set(
    events
      .filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain")
      .map((e) => `${e.pid}:${e.tid}`),
  );
  // Only top-level tasks: a nested RunTask (a task run inside another, as a sync IPC wait does) is part of its parent.
  const tasks = events
    .filter((e) => e.ph === "X" && TASK_NAMES.has(e.name) && mains.has(`${e.pid}:${e.tid}`))
    .sort((a, b) => a.ts - b.ts);
  const out: number[] = [];
  let openUntil = Number.NEGATIVE_INFINITY;
  for (const task of tasks) {
    const end = task.ts + (task.dur ?? 0);
    if (task.ts < openUntil) continue;
    openUntil = end;
    out.push((task.dur ?? 0) / 1000);
  }
  return out;
}

export function mainTaskStats(durations: number[]): MainTaskStats {
  const sorted = [...durations].sort((a, b) => a - b);
  const round = (v: number) => Math.round(v * 100) / 100;
  const at = (q: number) => (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]! : 0);
  return {
    main_tasks: sorted.length,
    main_task_max_ms: round(sorted.at(-1) ?? 0),
    main_task_p99_ms: round(at(0.99)),
    main_tasks_over_2ms: sorted.filter((d) => d > 2).length,
    main_tasks_over_4ms: sorted.filter((d) => d > 4).length,
    main_tasks_over_8ms: sorted.filter((d) => d > 8).length,
  };
}
