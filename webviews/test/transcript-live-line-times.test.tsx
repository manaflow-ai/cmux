// l10n-allow-file: test fixture commands, not shipped UI.
// The live line never says two bare durations side by side (Leo's capture, 2026-11-07, of
// "python3 - <<'EOF' 3s · 21s · 549 tokens": nothing said which time was the step's and which the
// turn's). By default each is named, "step 3s · turn 21s"; the gallery's
// agent-pane.live-line-times compares that with the turn's clock alone and with the step's time
// alone, the turn's on hover (liveLineTimes.experiment.ts).
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { WorkingCountsContext, type WorkingCounts } from "../src/agent-session/acpmux/conversation/workingForModel";

const START = Date.UTC(2026, 10, 7, 9, 0, 0);
const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 549,
};
const scope = globalThis as { cmuxExperiments?: Record<string, string> };
afterEach(() => {
  delete scope.cmuxExperiments;
});

/// The words a reader sees: generated shimmer copies and inert size samples are not text.
const drawn = (props: Parameters<typeof Thinking>[0]) =>
  renderToStaticMarkup(
    <WorkingCountsContext.Provider value={counts}>
      <Thinking since={START} now={() => START + 21_000} below turnTotal {...props} />
    </WorkingCountsContext.Provider>,
  )
    .replace(/<[^>]*aria-hidden="true"[^>]*><\/span>/g, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

const finished = { doing: "python3 - <<'EOF'", doingShell: false, done: true, doneMs: 3_000 } as const;

test("a finished step's time and the turn's clock are each named, never two bare durations", () => {
  const text = drawn(finished);
  expect(text).toContain("step 3s");
  expect(text).toContain("turn 21s");
  expect(text).not.toMatch(/\b3s · 21s\b/);
});

test("the summed thinking beside Thinking stays bare; only the turn's clock is named", () => {
  expect(drawn({ thoughtMs: 8_000 })).toContain("Thinking 8s · turn 21s");
});

test("the other arms: the turn's clock alone, or the step's time with the turn's in its tooltip", () => {
  scope.cmuxExperiments = { "live-line-times": "turn" };
  const turnOnly = drawn(finished);
  expect(turnOnly).toContain("21s");
  expect(turnOnly).not.toContain("3s");
  scope.cmuxExperiments = { "live-line-times": "hover" };
  const markup = renderToStaticMarkup(
    <WorkingCountsContext.Provider value={counts}>
      <Thinking since={START} now={() => START + 21_000} below turnTotal {...finished} />
    </WorkingCountsContext.Provider>,
  );
  expect(markup).toContain('title="turn 21s"');
  expect(drawn(finished)).not.toContain("21s");
});
