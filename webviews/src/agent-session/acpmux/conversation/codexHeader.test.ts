// l10n-allow-file: test fixtures.
// A finished Codex turn's header, as Codex's own (Leo, 2026-11-02: "i assume the x previous messages
// are when there's a mix and the worked for is if it's one contiguous thing ... let's follow those"):
// work with the agent's messages between it reads "N previous messages", work alone "Worked for".
// A Claude turn draws no header by default; only its opt-in (turnFoldStyle.ts) folds it under "Worked for".
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

test("work with the agent's messages between it reads N previous messages", () => {
  const row = header([
    prompt,
    work("w1", 1_000, 2),
    say("n1", 10_000, "Found the cause in the parser."),
    work("w2", 20_000, 3),
    say("a", 50_000, "Done."),
    end,
  ]);
  // Five calls and the one message between them; the answer stays below the header.
  expect(row?.previous).toBe(6);
  expect(workedLabel(t, row!)).toBe("6 previous messages");
});

test("a Claude turn keeps its per-run folding and draws no header", () => {
  const rows = [
    prompt,
    work("w1", 1_000, 2),
    say("n1", 10_000, "Found the cause."),
    work("w2", 20_000, 1),
    say("a", 50_000, "Done."),
    end,
  ];
  expect(header(rows, "claude")).toBeUndefined();
});

test("a message joining the fold redraws the header: its count is part of the row's version", () => {
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
  expect(after?.previous).toBe(6);
  expect(after?.version).not.toBe(before?.version);
});
