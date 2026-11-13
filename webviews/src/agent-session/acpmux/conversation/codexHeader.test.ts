// l10n-allow-file: test fixtures.
// Finished Codex and Claude work folds read Worked for, including commentary between calls.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { WORKED, turnView, workedLabel } from "./turns";

const t = ((key: string, values?: Record<string, unknown>) =>
  key === "turn.previous.one"
    ? "1 previous message"
    : key === "turn.previous.other"
      ? `${String(values!.n)} previous messages`
      : key === "turn.worked"
        ? `Worked for ${String(values!.time)}`
        : key) as Parameters<typeof workedLabel>[0];

const call = (id: string) => ({
  kind: "tool",
  text: "Run",
  tool: { id, title: "Run", kind: "execute", status: "completed" },
});
const prompt: AcpmuxRow = { id: "p", version: 1, at: 0, kind: "user", text: "Fix it" };
const work = (id: string, at: number, n: number) =>
  ({
    id,
    version: 1,
    at,
    kind: "activity",
    items: Array.from({ length: n }, (_, i) => call(`${id}-${i}`)),
  }) as AcpmuxRow;
const say = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text });
const end: AcpmuxRow = {
  id: "s",
  version: 1,
  at: 60_000,
  kind: "turnSummary",
  status: "completed",
  durationMs: 60_000,
};
const header = (rows: AcpmuxRow[], agentFamily = "codex") =>
  turnView(rows, new Set(), { now: 70_000, agentFamily }).find((row) => row.kind === WORKED);

test("one stretch of work reads Worked for", () => {
  const row = header([prompt, work("w", 1_000, 3), say("a", 50_000, "Done."), end]);
  expect(row?.previous).toBeUndefined();
  expect(workedLabel(t, row!)).toBe("Worked for 1m");
});

test("work with commentary between calls keeps the Worked for header", () => {
  const row = header([
    prompt,
    work("w1", 1_000, 2),
    say("n1", 10_000, "Found the cause in the parser."),
    work("w2", 20_000, 3),
    say("a", 50_000, "Done."),
    end,
  ]);
  expect(row?.previous).toBeUndefined();
  expect(workedLabel(t, row!)).toBe("Worked for 1m");
});

test("a Claude turn reads Worked for, never a message count", () => {
  const rows = [
    prompt,
    work("w1", 1_000, 2),
    say("n1", 10_000, "Found the cause."),
    work("w2", 20_000, 1),
    say("a", 50_000, "Done."),
    end,
  ];
  const row = header(rows, "claude");
  expect(row?.previous).toBeUndefined();
  expect(workedLabel(t, row!)).toBe("Worked for 1m");
});

test("commentary joining the fold stays available when the unchanged header opens", () => {
  const before = header([prompt, work("w1", 1_000, 2), work("w2", 20_000, 3), say("a", 50_000, "Done."), end]);
  const after = header([
    prompt,
    work("w1", 1_000, 2),
    say("n1", 10_000, "Found the cause in the parser."),
    work("w2", 20_000, 3),
    say("a", 50_000, "Done."),
    end,
  ]);
  expect(before?.previous).toBeUndefined();
  expect(after?.previous).toBeUndefined();
  expect(workedLabel(t, after!)).toBe("Worked for 1m");
  expect(after?.version).toBe(before?.version);
  const open = turnView(
    [
      prompt,
      work("w1", 1_000, 2),
      say("n1", 10_000, "Found the cause in the parser."),
      work("w2", 20_000, 3),
      say("a", 50_000, "Done."),
      end,
    ],
    new Set([after!.id]),
    { now: 70_000, agentFamily: "codex" },
  );
  expect(open.find((row) => row.id === "n1")?.text).toBe("Found the cause in the parser.");
});
