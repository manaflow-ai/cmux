// l10n-allow-file: test fixture commands and replies, not shipped UI.
// The live line's own time beside a finished step ("Ran grep 2s · 15s"): Leo, 2026-11-05, on
// "Identify which wait belongs to the relay-login green step 0s · 32s · 384 tokens": "this thing
// is cool but it always only shows 0s?". The fixture is one real Claude turn through acpmux
// (test/fixtures/claude-subagent-launch.ndjson): a Bash call that ran 856ms, then a background
// Agent call whose result is only its launch, 411ms after it started.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { renderToStaticMarkup as renderMarkup } from "react-dom/server";
import type { ReactNode } from "react";
import { mergeToolItem } from "../src/agent-session/acpmux/direct";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { StatusVerbContext } from "../src/agent-session/acpmux/statusVerbs";

type Event = { seq: number; at: number; kind: string; msg: { params: { update: Record<string, any> } } };
const events: Event[] = readFileSync(new URL("./fixtures/claude-subagent-launch.ndjson", import.meta.url), "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line));

/// Each call as the pane folds its events (direct.ts mergeToolItem, stamped with each event's time).
function calls(): Map<string, AcpmuxActivity> {
  const items = new Map<string, AcpmuxActivity>();
  for (const event of events) {
    const update = event.msg.params.update;
    if (event.kind !== "tool_call" && event.kind !== "tool_call_update") continue;
    const id = String(update.toolCallId);
    items.set(id, mergeToolItem(items.get(id), update, id, "", event.at));
  }
  return items;
}
const [bash, agent] = [...calls().values()];

const prompt: AcpmuxRow = { id: "u", kind: "user", version: 1, at: events[0]!.at - 20_000 };
const run = (...items: AcpmuxActivity[]): AcpmuxRow => ({
  id: "run",
  kind: "activity",
  version: 1,
  at: prompt.at,
  items,
});
const line = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { working: true }).find((row) => row.kind === THINKING)!;
const words = (node: ReactNode) =>
  renderMarkup(
    <StatusVerbContext.Provider value={{ mode: "thinking", verbs: ["Thinking"] }}>{node}</StatusVerbContext.Provider>,
  )
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const drawn = (row: AcpmuxRow, now: number) =>
  words(
    <Thinking
      since={row.at}
      doing={row.doing}
      doingShell={row.doingShell}
      done={row.doingDone}
      doneMs={row.doingForMs}
      thoughtMs={row.thoughtMs}
      turnTotal={row.turnTotal}
      now={() => now}
    />,
  );

test("the fixture's calls carry the times Claude's events gave them", () => {
  expect(bash!.tool!.endedAt! - bash!.tool!.startedAt!).toBe(856);
  expect(agent!.tool!.endedAt! - agent!.tool!.startedAt!).toBe(411);
});

test("a step that ran under a second gives the line back to Thinking, never a floored 0s", () => {
  // The line reads Thinking the moment the call completes (Leo, 2026-11-07: "Why don't we just
  // immediately switch to the thinking?"), never the finished step with its frozen time.
  const live = line([prompt, run(bash!)]);
  expect(live.doing).toBeUndefined();
  expect(drawn(live, prompt.at + 32_000)).toBe("Thinking 32s");
});

test("a subagent's launch never stands on the line as a step with its launch's time", () => {
  // Its call ended when the subagent started, in the background: the call's 411ms is no time of
  // the subagent's, which has its own row and clock.
  const live = line([prompt, run(bash!, agent!)]);
  expect(live.doing ?? "").not.toContain("Identify which wait");
  expect(drawn(live, prompt.at + 32_000)).not.toMatch(/\b0s\b/);
  // The same launch with its input withheld (a replay that kept only its title) is still a launch.
  const bare = { ...agent!, tool: { ...agent!.tool!, inputSummary: undefined } };
  expect(line([prompt, run(bash!, bare)]).doing ?? "").not.toContain("Identify which wait");
});

test("a step stamped at one moment has no time of its own: the line shows only the turn's", () => {
  const instant = { ...bash!, tool: { ...bash!.tool!, endedAt: bash!.tool!.startedAt } };
  const live = line([prompt, run(instant)]);
  expect(live.doingForMs).toBeUndefined();
  expect(drawn(live, prompt.at + 32_000)).toBe("Thinking 32s");
});

test("thinking that streamed under a second says its time; one dated chunk has none", () => {
  const at = events[0]!.at;
  const thought = (startedAt: number, endedAt: number): AcpmuxActivity => ({
    kind: "thought",
    text: "Check the wait",
    startedAt,
    endedAt,
  });
  const brief = line([prompt, { ...run(), items: [thought(at, at + 420)] }]);
  expect(brief.thoughtMs).toBe(420);
  // The Labelled arm names both times; the default says the turn's clock alone (liveLineTimes.experiment.ts).
  expect(drawn(brief, prompt.at + 32_000)).toBe("Thinking 32s");
  (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "live-line-times": "labelled" };
  try {
    expect(drawn(brief, prompt.at + 32_000)).toBe("Thinking 420ms · turn 32s");
  } finally {
    delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
  }
  const single = line([prompt, { ...run(), items: [thought(at, at)] }]);
  expect(single.thoughtMs).toBeUndefined();
  expect(drawn(single, prompt.at + 32_000)).toBe("Thinking 32s");
});

test("every finished row's own time: milliseconds under a second, none for one stamped at one moment", async () => {
  const { spanDuration } = await import("../src/agent-session/acpmux/conversation/turns");
  const t = ((key: string, args: { n: number }) => (key === "duration.ms" ? `${args.n}ms` : key)) as never;
  // The background launch's call, as the fixture times it, and the Bash step.
  expect(spanDuration(t, agent!.tool!.endedAt! - agent!.tool!.startedAt!)).toBe("411ms");
  expect(spanDuration(t, 32_000)).toBe("32s");
  expect(spanDuration(t, 0)).toBeUndefined();
  expect(spanDuration(t, -5)).toBeUndefined();
});

test("no finished span is drawn with formatDuration, which floors under a second to 0s", async () => {
  // The detector for the class: a finished call, command or scheduled run's end minus its start
  // goes through spanDuration ("856ms", or no time for a span stamped at one moment). A live clock
  // ticking from its start may read "0s" for its first second; a finished one never does.
  const { readdirSync, statSync } = await import("node:fs");
  const { join } = await import("node:path");
  const root = new URL("../src", import.meta.url).pathname;
  const files = (dir: string): string[] =>
    readdirSync(dir).flatMap((name) => {
      const path = join(dir, name);
      return statSync(path).isDirectory() ? files(path) : /\.tsx?$/.test(name) ? [path] : [];
    });
  const offenders = files(root).flatMap((path) =>
    readFileSync(path, "utf8")
      .split("\n")
      .flatMap((text, index) =>
        /formatDuration\(.*\bendedAt\b/.test(text) ? [`${path.slice(root.length + 1)}:${index + 1}`] : [],
      ),
  );
  expect(offenders).toEqual([]);
});
