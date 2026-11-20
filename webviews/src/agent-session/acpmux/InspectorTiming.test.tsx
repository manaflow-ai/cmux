// l10n-allow-file: synthetic test fixtures.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { SessionFlameGraph, type InspectorTurn } from "./InspectorTiming";

const turn: InspectorTurn = {
  seq: 1,
  startedAt: 1000,
  endedAt: 11000,
  wallMs: 10000,
  prompt: "Inspect",
  status: "completed",
};

test("missing send stamps stay unknown; a recorded zero delay is shown", () => {
  const absent = renderToStaticMarkup(<SessionFlameGraph turns={[turn]} />);
  expect(absent).toContain("unknown");
  expect(absent).not.toContain("is-send");
  const zero = renderToStaticMarkup(<SessionFlameGraph turns={[{ ...turn, toAgentMs: 0 }]} />);
  expect(zero).toContain("0ms");
  expect(zero).toContain("is-send");
});

test("idle time stays on the session axis instead of packing turns together", () => {
  const html = renderToStaticMarkup(
    <SessionFlameGraph turns={[turn, { ...turn, seq: 2, startedAt: 31000, endedAt: 41000 }]} />,
  );
  expect(html).toContain("--timing-from:75%");
  expect(html).toContain("--timing-width:25%");
});

test("a running turn with no end does not invent elapsed time", () => {
  const html = renderToStaticMarkup(
    <SessionFlameGraph turns={[{ seq: 1, startedAt: 1000, prompt: "Running", status: "running" }]} />,
  );
  expect(html).not.toContain('class="acpmux-timing-bar"');
  expect(html).not.toContain("NaN");
  expect(html).not.toContain("Infinity");
});
