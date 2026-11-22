import { describe, expect, test } from "bun:test";

// A highlight job that takes longer than its budget (a grammar stuck on hostile input) must not
// hold a worker forever: the worker is replaced, the job ends as an error (its card draws as plain
// text), and the next job runs on the fresh worker.
const { WatchedWorker, HIGHLIGHT_BUDGET_MS } = await import("./highlightWatchdog");

class FakeWorker extends EventTarget {
  static made: FakeWorker[] = [];
  sent: unknown[] = [];
  terminated = false;
  constructor() {
    super();
    FakeWorker.made.push(this);
  }
  postMessage(message: unknown) {
    this.sent.push(message);
  }
  terminate() {
    this.terminated = true;
  }
  answer(data: unknown) {
    this.dispatchEvent(new MessageEvent("message", { data }));
  }
}

function fakeClock() {
  let now = 0;
  const timers = new Map<number, { at: number; run: () => void }>();
  let next = 1;
  return {
    setTimeout: (run: () => void, ms: number) => {
      timers.set(next, { at: now + ms, run });
      return next++;
    },
    clearTimeout: (id: number) => void timers.delete(id),
    advance(ms: number) {
      now += ms;
      const due = [...timers].filter(([, timer]) => timer.at <= now);
      for (const [id, timer] of due) {
        timers.delete(id);
        timer.run();
      }
    },
  };
}

describe("highlight time budget", () => {
  test("the budget is about two seconds", () => {
    expect(HIGHLIGHT_BUDGET_MS).toBe(2_000);
  });

  test("a slow job is cut off: the worker is replaced, set up again, and the job answers with an error", () => {
    FakeWorker.made = [];
    const clock = fakeClock();
    const slow: string[] = [];
    const watched = new WatchedWorker(() => new FakeWorker() as unknown as Worker, {
      clock,
      onTimeout: (name) => slow.push(name),
    });
    const answers: { type: string; id: string }[] = [];
    watched.addEventListener("message", (event) => answers.push((event as MessageEvent).data));
    const init = { type: "initialize", id: "i1" };
    watched.postMessage(init);
    FakeWorker.made[0]!.answer({ type: "success", id: "i1", requestType: "initialize" });
    watched.postMessage({ type: "file", id: "f1", file: { name: "snippet-7", contents: "x" } });
    clock.advance(HIGHLIGHT_BUDGET_MS - 1);
    expect(FakeWorker.made).toHaveLength(1);
    clock.advance(1);
    expect(FakeWorker.made[0]!.terminated).toBe(true);
    expect(FakeWorker.made).toHaveLength(2);
    // The fresh worker gets the same setup before any new job.
    expect(FakeWorker.made[1]!.sent).toEqual([init]);
    expect(answers.at(-1)).toMatchObject({ type: "error", id: "f1" });
    expect(slow).toEqual(["snippet-7"]);
    // A late answer from the old worker is dropped.
    FakeWorker.made[0]!.answer({ type: "success", id: "f1" });
    expect(answers.filter((answer) => answer.id === "f1")).toHaveLength(1);
  });

  test("a job that answers in time keeps its worker", () => {
    FakeWorker.made = [];
    const clock = fakeClock();
    const watched = new WatchedWorker(() => new FakeWorker() as unknown as Worker, { clock });
    const answers: unknown[] = [];
    watched.addEventListener("message", (event) => answers.push((event as MessageEvent).data));
    watched.postMessage({ type: "file", id: "f2", file: { name: "snippet-1", contents: "x" } });
    clock.advance(500);
    FakeWorker.made[0]!.answer({ type: "success", id: "f2" });
    clock.advance(5_000);
    expect(FakeWorker.made).toHaveLength(1);
    expect(answers).toEqual([{ type: "success", id: "f2" }]);
  });

  test("a worker that fails to start is reported once, so a blocked worker is never silent", () => {
    FakeWorker.made = [];
    const failures: string[] = [];
    const watched = new WatchedWorker(() => new FakeWorker() as unknown as Worker, {
      clock: fakeClock(),
      onStartFailure: (reason) => failures.push(reason),
    });
    FakeWorker.made[0]!.dispatchEvent(new Event("error"));
    FakeWorker.made[0]!.dispatchEvent(new Event("error"));
    expect(failures).toHaveLength(1);
    watched.terminate();
  });
});
