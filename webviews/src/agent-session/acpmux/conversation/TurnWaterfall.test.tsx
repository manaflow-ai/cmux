// l10n-allow-file: test fixture tool titles, not shipped UI.
// A finished turn's Timeline (TurnWaterfall.tsx, waterfallSpans.ts): the footer carries its timed
// calls, draws a closed clock button for them and nothing more until the reader opens it; opened,
// each call is a bar on the turn's axis that opens its row.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { TurnFooter } from "./TurnRows";
import { SummaryRow } from "../rows/SummaryRow";
import { sameRowFrame } from "../virtualTranscriptModel";
import { TurnWaterfall } from "./TurnWaterfall";
import { TurnActionsContext } from "./turnActions";
import { turnView } from "./turns";
import { turnWork, waterfall, waterfallCharts, waterfallLines, WATERFALL_FIRST, workEnds } from "./waterfallSpans";

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
      <TurnWaterfall form="chart" row={row} work={work} />
    </TurnActionsContext.Provider>,
  );
  expect(linked.match(/<button [^>]*class="cv-waterfall__span/g)?.length).toBe(WATERFALL_FIRST);
  expect(linked).toContain('data-tool-id="c0"');
  expect(linked).not.toContain(`data-tool-id="c${WATERFALL_FIRST}"`);
  expect(linked).toContain("Show 5 more");
  // Without a way to open a call (a gallery, a replay), a bar is not a button.
  expect(renderToStaticMarkup(<TurnWaterfall form="chart" row={row} work={work} />)).not.toMatch(
    /<button [^>]*class="cv-waterfall__span/,
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

test("a background shell that ends after the summary changes the footer's end key, so its memoized row redraws", () => {
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
  expect(workEnds(footer(5_000).turnWork)).not.toBe(workEnds(footer().turnWork));
  // The row's memo compares that key beside the version (rows/SummaryRow.tsx).
  const memo = (SummaryRow as unknown as { compare: (a: { row: AcpmuxRow }, b: { row: AcpmuxRow }) => boolean })
    .compare;
  expect(memo({ row: footer() }, { row: footer(5_000) })).toBe(false);
  expect(memo({ row: footer(5_000) }, { row: footer(5_000) })).toBe(true);
  // So does the transcript's frame around it, which would otherwise never reach the row's memo.
  expect(sameRowFrame({ row: footer() }, { row: footer(5_000) })).toBe(false);
  expect(sameRowFrame({ row: footer(5_000) }, { row: footer(5_000) })).toBe(true);
});

test("the end key is exact: 64 more ends, or one end a few ms later, still change it", () => {
  const ended = (n: number): AcpmuxActivity[] =>
    Array.from({ length: n }, (_, at) => ({
      kind: "tool",
      text: "sleep",
      tool: {
        id: `bg${at}`,
        title: "sleep",
        kind: "execute",
        status: "completed",
        background: { state: "completed", endedAt: 5_000 + at * 37 },
      },
    }));
  expect(workEnds(ended(65))).not.toBe(workEnds(ended(1)));
  const later = ended(1);
  later[0]!.tool!.background!.endedAt! += 64;
  expect(workEnds(later)).not.toBe(workEnds(ended(1)));
  expect(workEnds(undefined)).toBe("");
});

test("two spans of one reused call id draw under their own keys", () => {
  const markup = renderToStaticMarkup(
    <TurnWaterfall
      form="chart"
      row={{ at: 2_000, durationMs: 2_000 }}
      work={[call("same", 0, 500), call("same", 1_000, 1_500)]}
    />,
  );
  expect(markup.match(/class="cv-waterfall__span is-read/g)?.length).toBe(2);
});

test("the header's empty corner says the turn's total and its calls, in the axis's time format", () => {
  const shell = (id: string, from: number, to: number): AcpmuxActivity => ({
    kind: "tool",
    text: `sleep ${id}`,
    tool: {
      id,
      title: `sleep ${id}`,
      kind: "execute",
      command: `sleep ${id}`,
      status: "completed",
      startedAt: from,
      endedAt: to,
    },
  });
  const summary = (markup: string) =>
    markup.match(/class="cv-waterfall__summary"[^>]*>(.*?)<\/span><div/)?.[1]?.replace(/<[^>]+>/g, "");
  // Three commands over a 1m 30s turn (Leo's screenshot): the corner reads as the table's total.
  const commands = renderToStaticMarkup(
    <TurnWaterfall
      form="chart"
      row={{ at: 90_000, durationMs: 90_000 }}
      work={[shell("1", 0, 2_000), shell("2", 2_000, 6_000), shell("3", 6_000, 89_000)]}
    />,
  );
  expect(summary(commands)).toBe("3 commands · 1m 30s");
  // The corner sits in the header row, before the axis, so it shares the axis's line.
  expect(commands.indexOf("cv-waterfall__summary")).toBeLessThan(commands.indexOf("cv-waterfall__axis"));
  // Mixed kinds of call count as calls; one is singular; a thought is not a call.
  const thought: AcpmuxActivity = { kind: "thought", text: "Hmm", startedAt: 0, endedAt: 500 };
  expect(
    summary(
      renderToStaticMarkup(
        <TurnWaterfall
          form="chart"
          row={{ at: 4_200, durationMs: 4_200 }}
          work={[thought, shell("1", 500, 1_000), call("a", 1_000, 4_000)]}
        />,
      ),
    ),
  ).toBe("2 calls · 4s");
  expect(
    summary(
      renderToStaticMarkup(
        <TurnWaterfall form="chart" row={{ at: 840, durationMs: 840 }} work={[call("a", 0, 800)]} />,
      ),
    ),
  ).toBe("1 call · 840ms");
});

test("at a phone's width (390px, under the 420px container query) the header corner takes its own line and truncates", () => {
  const css = readFileSync(new URL("./TurnWaterfall.css", import.meta.url), "utf8");
  const rule = (block: string, selector: string) =>
    block.match(new RegExp(`${selector.replace(/[.]/g, "\\.")}\\s*\\{([^}]*)\\}`))?.[1] ?? "";
  // Wide: the header row is the rows' grid, so the corner is the label column.
  expect(rule(css, ".cv-waterfall__head")).toContain(
    "grid-template-columns: var(--wf-label-width, 38%) minmax(0, 1fr) var(--wf-time)",
  );
  expect(rule(css, ".cv-waterfall__span,\n.cv-waterfall__lane")).toContain(
    "grid-template-columns: var(--wf-label-width, 38%) minmax(0, 1fr) var(--wf-time)",
  );
  // It never pushes into the axis: it shrinks and ends in an ellipsis.
  const summary = rule(css, ".cv-waterfall__summary");
  for (const line of ["min-width: 0", "overflow: hidden", "text-overflow: ellipsis", "white-space: nowrap"])
    expect(summary).toContain(line);
  // 390px falls under the query; there the header is one column, the corner over the axis.
  const query = css.match(/@container \(max-width: (\d+)px\) \{([\s\S]*)\}\s*$/);
  expect(Number(query?.[1])).toBeGreaterThan(390);
  expect(rule(query![2]!, ".cv-waterfall.is-bars .cv-waterfall__head")).toContain(
    "grid-template-columns: minmax(0, 1fr)",
  );
  // And the corner is still drawn there, before the axis, with its words.
  const markup = renderToStaticMarkup(
    <div style={{ width: 390 }}>
      <TurnWaterfall form="chart" row={{ at: 90_000, durationMs: 90_000 }} work={[call("a", 0, 80_000)]} />
    </div>,
  );
  expect(markup).toMatch(
    /class="cv-waterfall__head"><span class="cv-waterfall__summary">.*1 call.*1m 30s.*<\/span><div class="cv-waterfall__axis"/,
  );
});

test("the turn's time outside every call is a last Model row, so the rows add up to the axis's total", () => {
  // Leo's screenshot (2026-11-05: "im not sure what the total thing is meant to represent. the total
  // time of a turn?"): one 2.7s read in a 14.1s turn left 11.4s of the axis blank.
  const chart = waterfall({ at: 14_100, durationMs: 14_100 }, [call("a", 0, 2_700)]);
  expect(chart.gaps).toEqual([{ from: 2_700, to: 14_100 }]);
  expect(chart.gapTotal).toBe(11_400);
  const markup = renderToStaticMarkup(
    <TurnWaterfall form="chart" row={{ at: 14_100, durationMs: 14_100 }} work={[call("a", 0, 2_700)]} />,
  );
  const model = markup.match(/<div [^>]*class="cv-waterfall__span is-model"[^>]*>(.*?)<\/div><span id=/)?.[1] ?? "";
  expect(model).toContain("Model, no tool running");
  expect(model).toContain(">11s<");
  // It comes after the call's row and is not a link to any call.
  expect(markup.indexOf("Read a.ts")).toBeLessThan(markup.indexOf("is-model"));
  expect(model).not.toContain("data-tool-id");
  // The axis starts at a bare 0: a moment, not a duration.
  expect(markup).toMatch(/class="cv-waterfall__axis"[^>]*><span>0<\/span>/);
  // Overlapping spans count once, and a gap is only what no span covers.
  const overlap = waterfall({ at: 10_000, durationMs: 10_000 }, [
    call("b", 1_000, 5_000),
    call("c", 2_000, 4_000),
    call("d", 6_000, 10_000),
  ]);
  expect(overlap.gaps).toEqual([
    { from: 0, to: 1_000 },
    { from: 5_000, to: 6_000 },
  ]);
  expect(overlap.gapTotal).toBe(2_000);
  // Back-to-back calls leave nothing to explain: no row.
  const tight = renderToStaticMarkup(
    <TurnWaterfall
      form="chart"
      row={{ at: 2_000, durationMs: 2_000 }}
      work={[call("e", 0, 1_000), call("f", 1_000, 2_000)]}
    />,
  );
  expect(tight).not.toContain("is-model");
  // The gallery's arms: shaded behind each track, or not drawn at all.
  const tint = renderToStaticMarkup(
    <TurnWaterfall
      form="chart"
      row={{ at: 14_100, durationMs: 14_100 }}
      work={[call("a", 0, 2_700)]}
      modelTime="tint"
    />,
  );
  expect(tint).not.toContain("is-model");
  expect(tint).toContain("cv-waterfall__gap");
  const none = renderToStaticMarkup(
    <TurnWaterfall
      form="chart"
      row={{ at: 14_100, durationMs: 14_100 }}
      work={[call("a", 0, 2_700)]}
      modelTime="none"
    />,
  );
  expect(none).not.toContain("is-model");
  expect(none).not.toContain("cv-waterfall__gap");
});

// Leo, 2026-11-22, on a 1m 40s turn drawn as a 551ms tick, one 24.5s bar and 1m 15s of stripes:
// "IF THIS IS THE CASE, THEN DON'T FUCKING DISPLAY THIS BULLSHIT LIKE THIS". A turn charts only with
// two or more visible call bars and the model's time under half the turn; any other is plain lines.
const sent = (from: number, to: number): AcpmuxActivity => ({
  kind: "tool",
  text: "Sent a message",
  tool: { id: "msg", title: "Sent a message", kind: "other", status: "completed", startedAt: from, endedAt: to },
});
const plainLines = (markup: string) =>
  [...markup.matchAll(/class="cv-waterfall__line[^"]*"[^>]*>(.*?)<\/(?:li|div|button)>/g)].map((m) =>
    m[1]!
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
      .trim(),
  );

test("Leo's turn (551ms thinking, one 24.5s call, 1m 15s of model time) is plain lines, not a chart", () => {
  const thought: AcpmuxActivity = { kind: "thought", text: "Hmm", startedAt: 25_000, endedAt: 25_551 };
  const row = { at: 100_400, durationMs: 100_400 };
  const work = [thought, sent(52_000, 76_500)];
  const chart = waterfall(row, work);
  expect(chart.gapTotal).toBeGreaterThan(chart.total / 2);
  expect(waterfallCharts(chart)).toBe(false);
  // Thinking is the thought and the model's time together: everything but the call.
  expect(waterfallLines(chart).map((line) => [line.span?.toolId, line.ms])).toEqual([
    [undefined, 75_900],
    ["msg", 24_500],
  ]);
  const markup = renderToStaticMarkup(<TurnWaterfall row={row} work={work} />);
  expect(markup).toContain("is-plain");
  expect(markup).not.toContain("cv-waterfall__axis");
  expect(markup).not.toContain("cv-waterfall__track");
  expect(markup).not.toContain("Model, no tool running");
  // Times read as the turn's "Worked for" does, and two lines end on the turn's Total with no
  // total over them (Leo, 2026-11-25: "the 34s is weird to have on both").
  expect(plainLines(markup)).toEqual(["Thinking 1m 15s", "Sent a message 24s", "Total 1m 40s"]);
  expect(markup).not.toContain("cv-waterfall__head");
});

test("a busy turn of many visible calls and little model time still charts", () => {
  const work = Array.from({ length: 8 }, (_, at) => call(`c${at}`, at * 1_000, at * 1_000 + 900));
  const row = { at: 8_000, durationMs: 8_000 };
  expect(waterfallCharts(waterfall(row, work))).toBe(true);
  const markup = renderToStaticMarkup(<TurnWaterfall row={row} work={work} />);
  expect(markup).toContain("cv-waterfall__axis");
  expect(markup).not.toContain("is-plain");
});

test("two calls with one under the 2% tick size, or half the turn on the model, are plain", () => {
  // Two calls, but one is a tick on a 100s axis: one visible bar is nothing to compare.
  const tick = waterfall({ at: 100_000, durationMs: 100_000 }, [call("a", 0, 60_000), call("b", 60_000, 61_000)]);
  expect(waterfallCharts(tick)).toBe(false);
  // Two visible calls, exactly half the turn on the model: plain.
  const half = waterfall({ at: 10_000, durationMs: 10_000 }, [call("a", 0, 2_500), call("b", 2_500, 5_000)]);
  expect(waterfallCharts(half)).toBe(false);
});

test("a turn with no calls (only thinking and model time) is one Thinking line", () => {
  const thought: AcpmuxActivity = { kind: "thought", text: "Hmm", startedAt: 0, endedAt: 3_000 };
  const row = { at: 30_000, durationMs: 30_000 };
  const chart = waterfall(row, [thought]);
  expect(waterfallCharts(chart)).toBe(false);
  expect(waterfallLines(chart)).toEqual([{ ms: 30_000 }]);
  const markup = renderToStaticMarkup(<TurnWaterfall row={row} work={[thought]} />);
  // One line is the total: no Total line and no head repeating "30s".
  expect(plainLines(markup)).toEqual(["Thinking 30s"]);
  expect(markup).not.toContain("cv-waterfall__head");
  expect(markup.match(/30s/g)).toHaveLength(1);
});

test("a turn of all model time around one call lists Thinking and the call, and its line opens the call", () => {
  const row = { at: 60_000, durationMs: 60_000 };
  const markup = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ showCall: () => true }}>
      <TurnWaterfall row={row} work={[call("a", 30_000, 30_200)]} />
    </TurnActionsContext.Provider>,
  );
  expect(plainLines(markup)).toEqual(["Thinking 59s", "Read a.ts 200ms", "Total 1m"]);
  expect(markup).toMatch(/<button type="button" class="cv-waterfall__line is-link" data-tool-id="a"/);
  // Calls that fill the whole turn leave no Thinking line.
  const busy = waterfall({ at: 1_000, durationMs: 1_000 }, [call("b", 0, 1_000)]);
  expect(waterfallLines(busy).map((line) => line.span?.toolId)).toEqual(["b"]);
});

// Leo, 2026-11-27, on a Timeline that read "Thinking 3ms" beside two calls of 2.2s and 2.5s: "was
// your thinkin really 3ms only? from anthropic and back?". Claude Code's thinking comes in one burst
// at its call's end, so its first to last chunk measured 3ms of a call's seconds. acpmux times each
// model call where it reads the stream (claude_stdio/model_calls.rs): request out, first byte, last
// token, and the Timeline draws those.
const queue = (from: number, to: number): AcpmuxActivity => ({
  kind: "tool",
  text: "Queue lands",
  tool: { id: "queue", title: "Queue lands", kind: "other", status: "completed", startedAt: from, endedAt: to },
});
const burst: AcpmuxActivity = { kind: "thought", text: "Queue both", startedAt: 5_997, endedAt: 6_000 };
const leosRows = (timed: boolean): AcpmuxRow[] => [
  {
    ...activity("a", [burst, queue(6_000, 8_200), sent(5_700, 8_200)]),
    ...(timed && {
      modelCalls: [
        { requestAt: 0, firstTokenAt: 2_100, lastTokenAt: 6_100, thought: true as const },
        { requestAt: 8_210, firstTokenAt: 9_900, lastTokenAt: 10_400 },
      ],
    }),
  },
];

test("before: a turn timed only by its thought chunks reads Thinking 3ms", () => {
  const work = turnWork(leosRows(false))!;
  const chart = waterfall({ at: 8_200 }, work);
  const thought = chart.spans.find((span) => !span.item.tool)!;
  expect(thought.to - thought.from).toBe(3);
});

test("a timed turn's model calls run from request to last token, in place of the burst of thought chunks", () => {
  const work = turnWork(leosRows(true))!;
  expect(work.map((item) => item.tool?.id ?? item.kind)).toEqual(["model", "msg", "queue", "model"]);
  const chart = waterfall({ at: 10_400, durationMs: 800 }, work);
  // The axis opens at the prompt's request, not at the first call.
  expect(chart.start).toBe(0);
  expect(chart.total).toBe(10_400);
  const models = chart.spans.filter((span) => span.item.kind === "model");
  expect(models.map((span) => [span.from, span.to])).toEqual([
    [0, 6_100],
    [8_210, 10_400],
  ]);
  // Thinking is the model's own time, request to last token: 6.1s and 2.19s, never 3ms.
  expect(waterfallLines(chart)[0]).toEqual({ ms: 8_290 });
  // The slowest is still a call.
  expect(chart.spans[chart.slowest!]!.toolId).toBe("msg");
  const markup = renderToStaticMarkup(<TurnWaterfall row={{ at: 10_400, durationMs: 800 }} work={work} form="chart" />);
  // The call that thought reads Thinking, the one that did not reads Model call, each with its wait.
  expect(markup).toContain("Thinking · 6s · first token after 2s");
  expect(markup).toContain("Model call · 2s · first token after 1s");
  expect(markup).not.toContain("3ms");
});

test("a model call whose request was not seen starts at its first byte and names no wait", () => {
  const rows: AcpmuxRow[] = [
    { ...activity("a", [queue(3_000, 4_000)]), modelCalls: [{ firstTokenAt: 1_000, lastTokenAt: 2_500 }] },
  ];
  const work = turnWork(rows)!;
  expect(work[0]).toMatchObject({ kind: "model", startedAt: 1_000, endedAt: 2_500 });
  const markup = renderToStaticMarkup(<TurnWaterfall row={{ at: 4_000 }} work={work} form="chart" />);
  expect(markup).toContain("Model call · 1s");
  expect(markup).not.toContain("first token");
});
