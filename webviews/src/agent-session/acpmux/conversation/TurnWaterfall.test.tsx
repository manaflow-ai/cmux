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
import { turnWork, waterfall, WATERFALL_FIRST, workEnds } from "./waterfallSpans";

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
    <TurnWaterfall row={{ at: 2_000, durationMs: 2_000 }} work={[call("same", 0, 500), call("same", 1_000, 1_500)]} />,
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
          row={{ at: 4_200, durationMs: 4_200 }}
          work={[thought, shell("1", 500, 1_000), call("a", 1_000, 4_000)]}
        />,
      ),
    ),
  ).toBe("2 calls · 4.2s");
  expect(
    summary(renderToStaticMarkup(<TurnWaterfall row={{ at: 840, durationMs: 840 }} work={[call("a", 0, 800)]} />)),
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
      <TurnWaterfall row={{ at: 90_000, durationMs: 90_000 }} work={[call("a", 0, 80_000)]} />
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
    <TurnWaterfall row={{ at: 14_100, durationMs: 14_100 }} work={[call("a", 0, 2_700)]} />,
  );
  const model = markup.match(/<div class="cv-waterfall__span is-model"[^>]*>(.*?)<\/div><\/li>/)?.[1] ?? "";
  expect(model).toContain("Model, no tool running");
  expect(model).toContain(">11.4s<");
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
    <TurnWaterfall row={{ at: 2_000, durationMs: 2_000 }} work={[call("e", 0, 1_000), call("f", 1_000, 2_000)]} />,
  );
  expect(tight).not.toContain("is-model");
  // The gallery's arms: shaded behind each track, or not drawn at all.
  const tint = renderToStaticMarkup(
    <TurnWaterfall row={{ at: 14_100, durationMs: 14_100 }} work={[call("a", 0, 2_700)]} modelTime="tint" />,
  );
  expect(tint).not.toContain("is-model");
  expect(tint).toContain("cv-waterfall__gap");
  const none = renderToStaticMarkup(
    <TurnWaterfall row={{ at: 14_100, durationMs: 14_100 }} work={[call("a", 0, 2_700)]} modelTime="none" />,
  );
  expect(none).not.toContain("is-model");
  expect(none).not.toContain("cv-waterfall__gap");
});
