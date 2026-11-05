// l10n-allow-file: test fixture tool titles, not shipped UI.
// A finished turn's Timeline (TurnWaterfall.tsx, waterfallSpans.ts): the footer carries its timed
// calls, draws a closed clock button for them and nothing more until the reader opens it; opened,
// each call is a bar on the turn's axis that opens its row.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { TurnFooter } from "./TurnRows";
import { TurnWaterfall } from "./TurnWaterfall";
import { TurnActionsContext } from "./turnActions";
import { turnView } from "./turns";
import { turnWork, waterfall, WATERFALL_FIRST } from "./waterfallSpans";

const call = (id: string, from: number | undefined, to: number | undefined, status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: `Read ${id}.ts`,
  tool: { id, title: `Read ${id}.ts`, kind: "read", status, startedAt: from, endedAt: to },
});

const activity = (id: string, items: AcpmuxActivity[]): AcpmuxRow => ({
  id,
  version: 1,
  at: 1_000,
  kind: "activity",
  items,
});

test("a turn's work is its timed calls and thoughts; an untimed call is left out, and nothing timed is none", () => {
  const thought: AcpmuxActivity = { kind: "thought", text: "Hmm", startedAt: 1_000, endedAt: 2_000 };
  const work = turnWork([activity("a", [thought, call("one", 2_000, 3_000), call("two", undefined, undefined)])]);
  expect(work?.map((item) => item.tool?.id ?? item.kind)).toEqual(["thought", "one"]);
  // A turn that only thought still has a Timeline of its thoughts.
  expect(turnWork([activity("a", [thought, call("two", 2_000, undefined)])])?.map((item) => item.kind)).toEqual([
    "thought",
  ]);
  expect(turnWork([activity("a", [call("two", 2_000, undefined)])])).toBeUndefined();
});

test("the axis starts at the turn's start; the slowest call and a failed one are marked", () => {
  const chart = waterfall({ at: 10_000, durationMs: 10_000 }, [
    call("one", 1_000, 2_000),
    call("two", 2_000, 8_000),
    call("three", 8_000, 9_000, "failed"),
  ]);
  expect(chart.start).toBe(0);
  expect(chart.total).toBe(10_000);
  expect(chart.spans.map((span) => [span.from, span.to])).toEqual([
    [1_000, 2_000],
    [2_000, 8_000],
    [8_000, 9_000],
  ]);
  expect(chart.slowest).toBe(1);
  expect(chart.spans.map((span) => span.failed)).toEqual([false, false, true]);
});

test("a finished turn's footer offers a closed Timeline and draws no waterfall until it is opened", () => {
  const rows: AcpmuxRow[] = [
    { id: "prompt", version: 1, at: 0, kind: "user", text: "Look" },
    activity("work", [call("one", 100, 400), call("two", 400, 900)]),
    { id: "answer", version: 1, at: 950, kind: "assistant", text: "Done." },
    { id: "summary", version: 1, at: 1_000, kind: "turnSummary", status: "completed", durationMs: 1_000 },
  ];
  const footer = turnView(rows, new Set(), { agentFamily: "claude", now: 10_000 }).find(
    (row) => row.kind === "turnSummary",
  )!;
  expect(footer.turnWork?.map((item) => item.tool?.id)).toEqual(["one", "two"]);
  const markup = renderToStaticMarkup(<TurnFooter row={footer} />);
  expect(markup).toContain('aria-label="Show timeline"');
  expect(markup).toContain('aria-expanded="false"');
  expect(markup).not.toContain("cv-waterfall__rows");
  // A footer without timed work draws no Timeline at all.
  expect(renderToStaticMarkup(<TurnFooter row={{ ...footer, turnWork: undefined }} />)).not.toContain("Show timeline");
});

test("an opened waterfall's bars open their calls, and a long one draws its first rows only", () => {
  const work = Array.from({ length: WATERFALL_FIRST + 5 }, (_, at) => call(`c${at}`, at * 100, at * 100 + 50));
  const row = { at: work.length * 100, durationMs: work.length * 100 };
  const linked = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ showCall: () => true }}>
      <TurnWaterfall row={row} work={work} />
    </TurnActionsContext.Provider>,
  );
  expect(linked.match(/<button type="button" class="cv-waterfall__span/g)?.length).toBe(WATERFALL_FIRST);
  expect(linked).toContain('data-tool-id="c0"');
  expect(linked).not.toContain(`data-tool-id="c${WATERFALL_FIRST}"`);
  expect(linked).toContain("Show 5 more");
  // Without a way to open a call (a gallery, a replay), a bar is not a button.
  expect(renderToStaticMarkup(<TurnWaterfall row={row} work={work} />)).not.toContain(
    '<button type="button" class="cv-waterfall__span',
  );
});

test("a background shell's bar runs until it ended there, and one that failed there is marked failed", () => {
  const shell: AcpmuxActivity = {
    kind: "tool",
    text: "bun test",
    tool: {
      id: "bg",
      title: "bun test",
      kind: "execute",
      command: "bun test",
      status: "completed",
      startedAt: 1_000,
      endedAt: 1_200,
      background: { state: "failed", endedAt: 9_000 },
    },
  };
  const chart = waterfall({ at: 10_000, durationMs: 10_000 }, [call("one", 500, 900), shell]);
  expect(chart.spans[1]).toMatchObject({ from: 1_000, to: 9_000, failed: true });
  expect(chart.slowest).toBe(1);
});

test("an empty footer (a turn gap, no line of its own) offers no Timeline it has no room to open", () => {
  const empty: AcpmuxRow = {
    id: "summary",
    version: 1,
    at: 1_000,
    kind: "turnSummary",
    status: "completed",
    durationMs: 1_000,
    turnWork: [call("one", 100, 400)],
  };
  expect(renderToStaticMarkup(<TurnFooter row={empty} />)).not.toContain("Show timeline");
});

test("a long thought is never the slowest: the tag names a call", () => {
  const thought: AcpmuxActivity = { kind: "thought", text: "Hmm", startedAt: 0, endedAt: 8_000 };
  const chart = waterfall({ at: 10_000, durationMs: 10_000 }, [
    thought,
    call("one", 8_000, 8_500),
    call("two", 8_500, 9_900),
  ]);
  expect(chart.slowest).toBe(2);
});

test("a background shell that ends after the summary gives the footer a new version, so its Timeline redraws", () => {
  const shell = (endedAt?: number): AcpmuxActivity => ({
    kind: "tool",
    text: "bun test",
    tool: {
      id: "bg",
      title: "bun test",
      kind: "execute",
      command: "bun test",
      status: "completed",
      startedAt: 100,
      endedAt: 200,
      background: endedAt === undefined ? { state: "running" } : { state: "completed", endedAt },
    },
  });
  const footer = (endedAt?: number) =>
    turnView(
      [
        { id: "prompt", version: 1, at: 0, kind: "user", text: "Look" },
        activity("work", [shell(endedAt)]),
        { id: "answer", version: 1, at: 950, kind: "assistant", text: "Done." },
        { id: "summary", version: 1, at: 1_000, kind: "turnSummary", status: "completed", durationMs: 1_000 },
      ],
      new Set(),
      { agentFamily: "claude", now: 10_000 },
    ).find((row) => row.kind === "turnSummary")!;
  expect(footer(5_000).version).not.toBe(footer().version);
});
