// l10n-allow-file: test fixture commands, not shipped UI.
// The running turn's live line says what is true now, on the page's clock, never what the last event
// was. Leo, 2026-11-12, on "Thinking 683ms · turn 15m 15s · 2.2K tokens": "this is... i guess maybe
// ok, but the whatever ms gets stuck and becomes false really quickly.... or else gets stale? idk
// what else you're actually doing so". The time beside Thinking ticks from when that stretch of
// thinking began (turns.ts `liveClock`), and once nothing has arrived for SILENT_MS the line says
// "Waiting", with the time since it last heard anything (Thinking.tsx).
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup as renderMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { SILENT_MS } from "../src/agent-session/acpmux/conversation/thinkingModel";
import { continuationStart, liveClock, THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { StatusVerbContext } from "../src/agent-session/acpmux/statusVerbs";
import { teardownDom } from "./support/domTeardown";

// The line's two times (liveLineTimes.experiment.ts `labelled`) on the line itself
// (liveTurnClock.experiment.ts `line`): this file reads the thinking time and the turn's clock.
const TWO_TIMES = { "live-turn-clock": "line", "live-line-times": "labelled" };
beforeEach(() => {
  globalThis.cmuxExperiments = { ...TWO_TIMES };
});
afterEach(() => {
  delete globalThis.cmuxExperiments;
});

const verbs = (node: ReactNode) => (
  <StatusVerbContext.Provider value={{ mode: "thinking", verbs: ["Thinking"] }}>{node}</StatusVerbContext.Provider>
);
const words = (html: string) =>
  html
    .replace(/<[^>]*aria-hidden="true"[^>]*><\/span>/g, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

const T0 = Date.UTC(2026, 10, 12, 9, 0, 0);
const prompt: AcpmuxRow = { id: "u", kind: "user", version: 1, at: T0 };
const activity = (id: string, at: number, items: AcpmuxActivity[]): AcpmuxRow => ({
  id,
  kind: "activity",
  version: 1,
  at,
  items,
});
const shell = (command: string, status: string, startedAt: number, endedAt?: number): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id: command, title: command, kind: "execute", status, command, startedAt, endedAt },
});
const thought = (startedAt: number, endedAt: number): AcpmuxActivity => ({
  kind: "thought",
  text: "Read where the status is checked first.",
  startedAt,
  endedAt,
});
const liveLine = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set(), { working: true }).find((row) => row.kind === THINKING)!;
const drawn = (line: AcpmuxRow, now: number) =>
  words(
    renderMarkup(
      verbs(
        <Thinking
          since={line.at}
          now={() => now}
          doing={line.doing}
          doingAt={line.doingAt}
          doingShell={line.doingShell}
          liveState={line.liveState}
          liveAgents={line.liveAgents}
          phaseAt={line.phaseAt}
          heardAt={line.heardAt}
          heardKey={line.heardKey}
          turnTotal={line.turnTotal}
          untimed={line.untimed}
          quietKey={line.quietKey}
          quietAt={line.quietAt}
        />,
      ),
    ),
  );

// The turn: a 30 s test run, then the agent thinks from 31 s to 33 s.
const ran = activity("run", T0 + 1_000, [shell("bun test", "completed", T0 + 1_000, T0 + 30_000)]);
const thinking = activity("think", T0 + 31_000, [thought(T0 + 31_000, T0 + 33_000)]);

test("the stretch of thinking starts where the last step ended, and the turn last heard its latest chunk", () => {
  expect(liveClock([prompt, ran, thinking], T0)).toEqual({ phaseAt: T0 + 30_000, heardAt: T0 + 33_000 });
  // A silence before the first chunk is no thinking: the stretch starts at that chunk.
  const late = activity("think", T0 + 52_000, [thought(T0 + 52_000, T0 + 53_000)]);
  expect(liveClock([prompt, ran, late], T0)).toEqual({ phaseAt: T0 + 52_000, heardAt: T0 + 53_000 });
  // Moved onto this computer's clock.
  expect(liveClock([prompt, ran, thinking], T0, 500)).toEqual({ phaseAt: T0 + 30_500, heardAt: T0 + 33_500 });
});

// Review of cmux#41871 (P1-F1): a thought keeps only its first and latest chunk's times, so a gap
// between those two is no silence; only a gap between thoughts is.
test("thinking that streams on past SILENT_MS keeps its stretch: the time never drops back to 0s", () => {
  const long = activity("think", T0 + 31_000, [thought(T0 + 31_000, T0 + 31_000 + SILENT_MS + 5_000)]);
  const heardAt = T0 + 31_000 + SILENT_MS + 5_000;
  expect(liveClock([prompt, ran, long], T0)).toEqual({ phaseAt: T0 + 30_000, heardAt });
  // Back-to-back thoughts, each a second after the last, are one stretch too.
  const chunks = Array.from({ length: 15 }, (_, i) => thought(T0 + 31_000 + i * 1_000, T0 + 31_500 + i * 1_000));
  expect(liveClock([prompt, ran, activity("think", T0 + 31_000, chunks)], T0).phaseAt).toBe(T0 + 30_000);
  expect(drawn(liveLine([prompt, ran, long]), heardAt + 1_000)).toStartWith(
    `Thinking ${(heardAt + 1_000 - (T0 + 30_000)) / 1_000}s`,
  );
  // A real silence between two thoughts still starts a new stretch at the later one.
  const after = activity("again", T0 + 33_000 + SILENT_MS, [thought(T0 + 33_000 + SILENT_MS, T0 + 34_000 + SILENT_MS)]);
  expect(liveClock([prompt, ran, thinking, after], T0).phaseAt).toBe(T0 + 33_000 + SILENT_MS);
});

// Review of cmux#41871 (P1-F2): a reply that paused reads Thinking past WRITING_MS, then Waiting
// past SILENT_MS, never a Thinking that stays for good.
test("a reply that paused turns to Waiting once nothing more arrives for SILENT_MS", () => {
  const reply: AcpmuxRow = { id: "a", kind: "assistant", version: 1, at: T0 + 31_000, text: "Reading the logs" };
  const line = liveLine([prompt, ran, reply]);
  expect(line.liveState).toBe("writing");
  expect(line.heardAt).toBe(reply.at);
  expect(drawn(line, reply.at + 1_000)).toStartWith("Writing");
  expect(drawn(line, reply.at + SILENT_MS + 2_000)).toBe(`Waiting ${(SILENT_MS + 2_000) / 1_000}s`);
});

test("the thinking time advances with the clock alone, no new event", () => {
  const line = liveLine([prompt, ran, thinking]);
  expect(drawn(line, T0 + 34_000)).toBe("Thinking 4s · turn 34s");
  expect(drawn(line, T0 + 38_000)).toBe("Thinking 8s · turn 38s");
});

test("after SILENT_MS with nothing heard the line says Waiting, calmly, with the time since it last heard", () => {
  const line = liveLine([prompt, ran, thinking]);
  const at = T0 + 33_000 + SILENT_MS + 2_000;
  expect(drawn(line, T0 + 33_000 + SILENT_MS - 1_000)).toStartWith("Thinking");
  expect(drawn(line, at)).toBe(`Waiting ${(SILENT_MS + 2_000) / 1_000}s · turn ${(at - T0) / 1_000}s`);
  const html = renderMarkup(
    verbs(
      <Thinking
        since={line.at}
        now={() => at}
        phaseAt={line.phaseAt}
        heardAt={line.heardAt}
        heardKey={line.heardKey}
        turnTotal
      />,
    ),
  );
  // No sweep says work goes on while it waits.
  expect(html).not.toContain("is-shimmer");
});

test("before the turn's first output it stays Thinking, however long the model takes", () => {
  const line = liveLine([prompt]);
  expect(drawn(line, T0 + 40_000)).toBe("Thinking 40s");
});

test("a call that runs long is never called Waiting", () => {
  const running = liveLine([prompt, activity("run", T0 + 1_000, [shell("bun test", "in_progress", T0 + 1_000)])]);
  expect(drawn(running, T0 + 120_000)).toStartWith("Running bun test");
});

test("the label changes when a tool starts", () => {
  const before = liveLine([prompt, ran, thinking]);
  expect(drawn(before, T0 + 34_000)).toStartWith("Thinking");
  const started = activity("next", T0 + 34_000, [shell("cargo check", "in_progress", T0 + 34_000)]);
  const after = liveLine([prompt, ran, thinking, started]);
  expect(after.doing).toBe("cargo check");
  expect(drawn(after, T0 + 35_000)).toBe("Running cargo check 35s");
});

test("with the default arms (one clock, the turn's over the work) the line still says Waiting, with how long", () => {
  globalThis.cmuxExperiments = {};
  const line = liveLine([prompt, ran, thinking]);
  const at = T0 + 33_000 + 14_000;
  // The turn's clock stands over the work ("Working for"): the line has no clock of its own while it thinks.
  expect(drawn({ ...line, untimed: true }, T0 + 34_000)).toBe("Thinking");
  expect(drawn({ ...line, untimed: true }, at)).toBe("Waiting 14s");
  // One clock on the line (`turn`): the turn's while it thinks, how long it heard nothing once it waits.
  globalThis.cmuxExperiments = { "live-turn-clock": "line" };
  const onLine = liveLine([prompt, ran, thinking]);
  expect(drawn(onLine, T0 + 34_000)).toBe("Thinking 34s");
  expect(drawn(onLine, at)).toBe("Waiting 14s");
});

// Leo, 2026-11-12, on "turn 19m 44s" for a coordinator whose turn stayed open while background
// notices kept arriving: "I feel like this is way too long for a turn".
test("a notice that set the agent going again after its reply starts the turn's clock over", () => {
  const reply: AcpmuxRow = { id: "a", kind: "assistant", version: 1, at: T0 + 60_000, text: "Opened the PR." };
  const notice: AcpmuxRow = {
    id: "n",
    kind: "user",
    version: 1,
    at: T0 + 19 * 60_000,
    text: "Background task finished",
    untyped: true,
    incoming: { kind: "notice", text: "Background task finished" },
  };
  expect(continuationStart([prompt, reply, notice], T0)).toBe(notice.at);
  // A notice before any reply is part of the person's turn; so is the person's own follow-up.
  expect(continuationStart([prompt, notice], T0)).toBe(T0);
  const followUp: AcpmuxRow = { id: "f", kind: "user", version: 1, at: T0 + 19 * 60_000, text: "and the docs" };
  expect(continuationStart([prompt, reply, followUp], T0)).toBe(T0);
  const line = liveLine([prompt, reply, notice]);
  expect(line.at).toBe(notice.at);
  expect(drawn(line, notice.at + 24_000)).toBe("Thinking 24s");
});

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Node",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  for (const key of keys)
    if (key !== "IS_REACT_ACT_ENVIRONMENT") scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
});
afterAll(() => teardownDom(saved, { window: dom.window }));

const seconds = (host: HTMLElement) => host.querySelector(".cv-worked__own")?.textContent ?? "";

test("in a mounted pane the thinking time ticks on the page's clock with no new props", async () => {
  const { subscribePageSecond } = await import("../src/ui/pageClock");
  const start = Date.now();
  const host = document.createElement("div");
  document.body.append(host);
  const root: Root = createRoot(host);
  await act(async () =>
    root.render(
      verbs(<Thinking since={start - 60_000} phaseAt={start - 2_000} heardAt={start} heardKey="k" turnTotal below />),
    ),
  );
  const first = seconds(host);
  expect(first).toMatch(/^\d+s$/);
  // Two of the page clock's seconds go by (its first call is its last sample, not a second).
  await act(
    async () =>
      new Promise<void>((resolve) => {
        let calls = 0;
        const stop = subscribePageSecond(() => {
          if (++calls < 3) return;
          stop();
          resolve();
        });
      }),
  );
  const later = seconds(host);
  expect(Number.parseInt(later), `the thinking time froze at ${first}`).toBeGreaterThan(Number.parseInt(first));
  await act(async () => root.unmount());
  host.remove();
});
