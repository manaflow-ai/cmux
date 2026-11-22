// Tearing down a test file's DOM globals without leaving React work behind.
//
// A file that installs its own window (JSDOM, happy-dom) and deletes those globals in afterAll or
// afterEach races React's scheduler: an update made outside act() (a popover, a resolved fetch, a
// timer) queues a scheduler task on setImmediate, and when that task runs after the globals are
// gone, react-dom reads `window.event` (performWorkOnRootViaSchedulerTask) and bun fails the file
// with "Unhandled error between tests: ReferenceError: window is not defined" and 0 failed tests
// (environment-picker.test.tsx, PR #40761's react-apps-base-check). Whether the task runs first
// depends on load, so the file passes alone and fails beside others.
//
// So every teardown that closes the window or deletes DOM globals first lets React finish:
// `teardownDom` for the usual "close the window, put the saved globals back" block, or
// `await settleReact()` before a teardown of another shape. dom-teardown-lint.test.ts fails on a
// test file that deletes DOM globals without it; dom-teardown-settles.test.ts is the forced repro.
import { createRequire } from "node:module";
import { dirname } from "node:path";
import { setImmediate as nextTurn } from "node:timers";

type Task = object;
type Callback = (didTimeout: boolean) => unknown;
type Scheduler = {
  unstable_scheduleCallback(priority: number, callback: Callback, options?: unknown): Task;
  unstable_cancelCallback(task: Task): void;
};

const PENDING = Symbol.for("cmux.test.reactSchedulerPending");
type Tracked = Scheduler & { [PENDING]?: Set<Task> };

// The scheduler react-dom itself loads (resolved from react-dom's folder: the same module instance,
// so its queue is the one React fills).
function reactScheduler(): Tracked {
  const require = createRequire(import.meta.url);
  const from = dirname(require.resolve("react-dom/package.json"));
  return require(require.resolve("scheduler", { paths: [from] })) as Tracked;
}

/// Counts the tasks React queues on its scheduler until each runs to the end or is cancelled. The
/// scheduler keeps its queue private, so this wraps its two entry points; react-dom copies them when
/// it first loads, so test/preload.ts calls this before it loads react-dom.
export function trackReactScheduler(): void {
  const scheduler = reactScheduler();
  if (scheduler[PENDING]) return;
  const pending = new Set<Task>();
  const schedule = scheduler.unstable_scheduleCallback;
  const cancel = scheduler.unstable_cancelCallback;
  scheduler.unstable_scheduleCallback = (priority, callback, options) => {
    let task: Task | undefined;
    // A callback that returns a function has more work: the scheduler keeps the task and calls that
    // continuation next, so the task stays pending until a call returns anything else.
    const run =
      (step: Callback): Callback =>
      (didTimeout) => {
        let next: unknown;
        try {
          next = step(didTimeout);
        } catch (error) {
          if (task) pending.delete(task);
          throw error;
        }
        if (typeof next === "function") return run(next as Callback);
        if (task) pending.delete(task);
        return next;
      };
    task = schedule(priority, run(callback), options);
    pending.add(task);
    return task;
  };
  scheduler.unstable_cancelCallback = (task) => {
    pending.delete(task);
    cancel(task);
  };
  scheduler[PENDING] = pending;
}

/// Whether React's scheduler has a task queued (a render or passive effects not yet run).
export function reactHasPendingWork(): boolean {
  const pending = reactScheduler()[PENDING];
  if (!pending) throw new Error("React's scheduler is not tracked: test/preload.ts calls trackReactScheduler()");
  return pending.size > 0;
}

/// The event-loop turns settleReact waits before it calls the scheduler stuck: a render loop that
/// schedules itself forever is a bug of its own, named here instead of hidden.
const MAX_TURNS = 1000;

/// Waits event-loop turns (node:timers setImmediate, which a file's fake global setImmediate does
/// not replace) until React's scheduler has nothing queued. Always waits one turn, so microtasks and
/// a setImmediate React already asked for run first.
export async function settleReact(): Promise<void> {
  for (let turn = 0; turn < MAX_TURNS; turn += 1) {
    await new Promise<void>((resolve) => nextTurn(resolve));
    if (!reactHasPendingWork()) return;
  }
  throw new Error(
    `React's scheduler still had work after ${MAX_TURNS} turns at teardown: something re-renders forever`,
  );
}

type Saved = Iterable<readonly [key: string, had: boolean, value: unknown]>;

/// The usual teardown: let React finish, close the window, then put back each saved global (`had`)
/// or delete the ones this file added.
export async function teardownDom(
  saved: Saved,
  {
    window,
    scope = globalThis as Record<string, unknown>,
  }: { window?: { close(): void }; scope?: Record<string, unknown> } = {},
): Promise<void> {
  await settleReact();
  window?.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
}
