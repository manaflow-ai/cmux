import { describe, expect, test } from "bun:test";
import { UNSENT_INPUT_OP, UnsentInputReport } from "../src/pages/home-channels/hostUnsentInput";

// A hidden Channels page with unsent composer input is kept, not discarded (p07-memory-027): the
// page tells the host each time it goes between no unsent input and some.
function host(fail = false) {
  const calls: { op: string; params: unknown }[] = [];
  return {
    calls,
    call<R>(op: string, params: unknown): Promise<R> {
      calls.push({ op, params });
      return fail ? Promise.reject(new Error("refused")) : Promise.resolve({} as R);
    },
  };
}

describe("Channels unsent input report", () => {
  test("the host hears only when the page goes between none and some", () => {
    const app = host();
    const report = new UnsentInputReport(app);
    const main = {};
    const thread = {};
    report.set(main, false);
    expect(app.calls).toEqual([]);
    report.set(main, true);
    report.set(thread, true);
    report.set(main, false);
    expect(report.unsent).toBe(true);
    report.set(thread, false);
    expect(report.unsent).toBe(false);
    expect(app.calls).toEqual([
      { op: UNSENT_INPUT_OP, params: { unsent: true } },
      { op: UNSENT_INPUT_OP, params: { unsent: false } },
    ]);
  });

  test("a report the host did not take is sent again with the next change", async () => {
    const app = host(true);
    const report = new UnsentInputReport(app);
    const composer = {};
    report.set(composer, true);
    await Promise.resolve();
    await Promise.resolve();
    report.set(composer, true);
    expect(app.calls.length).toBe(2);
  });
});
