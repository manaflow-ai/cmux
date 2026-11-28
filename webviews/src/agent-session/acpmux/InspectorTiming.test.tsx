// l10n-allow-file: synthetic test fixtures.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { SessionTiming, toFirstOutputMs, turnPhases, type InspectorTurn } from "./InspectorTiming";

const turn: InspectorTurn = {
  seq: 1,
  startedAt: 1000,
  endedAt: 11000,
  wallMs: 10000,
  prompt: "Inspect",
  status: "completed",
};

test("missing send stamps stay unknown; a recorded zero delay is shown", () => {
  const absent = renderToStaticMarkup(<SessionTiming turns={[turn]} />);
  expect(absent).toContain("unknown");
  expect(absent).not.toContain("is-send");
  const zero = renderToStaticMarkup(<SessionTiming turns={[{ ...turn, toAgentMs: 0 }]} />);
  expect(zero).toContain("0ms");
  expect(zero).toContain("is-send");
});

test("the phases run end to end from the message: to agent, queued, first output", () => {
  const phases = turnPhases({ ...turn, toAgentMs: 500, queuedMs: 2000, queuedOn: "busy", firstModelMs: 1500 });
  expect(phases).toEqual([
    { kind: "send", at: 1000, ms: 500 },
    { kind: "queued", at: 1500, ms: 2000 },
    { kind: "model", at: 3500, ms: 1500 },
  ]);
  expect(toFirstOutputMs({ ...turn, toAgentMs: 500, queuedMs: 2000, firstModelMs: 1500 })).toBe(4000);
  // No queue recorded: the model phase starts where the send ended.
  expect(turnPhases({ ...turn, toAgentMs: 500, firstModelMs: 1500 }).map((p) => p.kind)).toEqual(["send", "model"]);
  expect(toFirstOutputMs({ ...turn, toAgentMs: 500 })).toBeUndefined();
});

test("a compaction hold names the compaction", () => {
  const html = renderToStaticMarkup(
    <SessionTiming turns={[{ ...turn, toAgentMs: 5, queuedMs: 3000, queuedOn: "compacting", firstModelMs: 900 }]} />,
  );
  expect(html).toContain("is-queued");
  expect(html).toContain("compaction");
});

test("idle time stays on the session axis instead of packing turns together", () => {
  const html = renderToStaticMarkup(
    <SessionTiming turns={[turn, { ...turn, seq: 2, startedAt: 31000, endedAt: 41000 }]} />,
  );
  expect(html).toContain("--timing-from:75%");
  expect(html).toContain("--timing-width:25%");
});

test("a running turn with no end does not invent elapsed time", () => {
  const html = renderToStaticMarkup(
    <SessionTiming turns={[{ seq: 1, startedAt: 1000, prompt: "Running", status: "running" }]} />,
  );
  expect(html).not.toContain('class="acpmux-timing-bar"');
  expect(html).not.toContain("NaN");
  expect(html).not.toContain("Infinity");
});

test("no turns says none", () => {
  expect(renderToStaticMarkup(<SessionTiming turns={[]} />)).toContain("acpmux-timing-note");
});
