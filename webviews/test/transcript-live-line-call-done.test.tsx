// l10n-allow-file: test fixture commands, not shipped UI.
// The moment a call completes, the live line reads "Thinking": it never holds the finished command
// with its frozen time (Leo, 2026-11-07, on "…-v test … 1s · 2m 20s · 2K tokens": "if we can
// genuinely determine that there's no more seconds ticking, then why are we still showing it? Why
// don't we just immediately switch to the thinking? I feel like this hangs on for a bit too much").
// The line keeps its id (it never leaves and comes back), and the turn's clock goes on.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 7, 10, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const call = (status: string, extra: Partial<NonNullable<AcpmuxActivity["tool"]>> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: {
    id: "bash-1",
    title: "pytest -v test",
    kind: "execute",
    status,
    command: "pytest -v test",
    startedAt: START + 10_000,
    ...extra,
  },
});
const prompt = row("u-1", "user", 0, { text: "Run the tests" });
const view = (items: AcpmuxActivity[]) =>
  turnView([prompt, row("t-1", "activity", 10, { items })], new Set(), {
    working: true,
    agentFamily: "claude",
    now: START + 140_000,
  });
const words = (line: AcpmuxRow) =>
  renderToStaticMarkup(
    <Thinking
      since={line.at}
      now={() => START + 140_000}
      doing={line.doing}
      doingShell={line.doingShell}
      done={line.doingDone}
      doneMs={line.doingForMs}
      liveState={line.liveState}
      thoughtMs={line.thoughtMs}
      turnTotal={line.turnTotal}
      below
    />,
  )
    .replace(/<[^>]*aria-hidden="true"[^>]*><\/span>/g, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("a running command names itself on the line", () => {
  const line = view([call("in_progress")]).at(-1)!;
  expect(line).toMatchObject({ kind: THINKING, doing: "pytest -v test" });
});

test("a command that finished at once: the line reads Thinking, with no frozen step time", () => {
  const instant = call("completed", { endedAt: START + 10_000, output: "1 passed\n", exitCode: 0 });
  const line = view([instant]).at(-1)!;
  expect(line.id).toBe("thinking-live");
  expect(line.doing).toBeUndefined();
  expect(line.doingDone).toBeUndefined();
  expect(line.doingForMs).toBeUndefined();
  const text = words(line);
  expect(text).toStartWith("Thinking");
  expect(text).not.toContain("pytest");
  // The turn's clock goes on.
  expect(text).toContain("2m 20s");
});

test("a command whose output came after its last tick: completed is completed, the line reads Thinking", () => {
  // Its output landed late, on the update that completed it, 1 s after the call's own end.
  const lagged = call("completed", { endedAt: START + 11_000, output: "…\n120 passed\n", exitCode: 0 });
  const line = view([lagged]).at(-1)!;
  expect(line.doing).toBeUndefined();
  expect(words(line)).toStartWith("Thinking");
  expect(words(line)).not.toMatch(/\b1s ·/);
});
