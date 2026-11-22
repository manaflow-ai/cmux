// l10n-allow-file: measured usage and turn fixtures.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { usageSection } from "../src/agent-session/acpmux/session-info/native/usage";
import type { AcpmuxTimeBreakdown } from "../src/agent-session/acpmux/model";

const time: AcpmuxTimeBreakdown = {
  totalMs: 1_000,
  totalTokens: 10,
  tokensComplete: false,
  categories: [{ id: "run", wallMs: 1_000 }],
  spans: [{ turnSeq: 1, turnId: "turn-1", category: "run", startAt: 0, endAt: 1_000, turnTokens: 10 }],
};

test("native fallback exposes partial totals and an actionable turn without inventing category usage", async () => {
  const actions = new NativeInfoActions();
  let revealed: string | undefined;
  const model = usageSection(
    {
      sessions: [],
      open: true,
      timeBreakdown: time,
      onShowTurn: (id) => {
        revealed = id;
      },
    },
    actions,
    translate,
  )!;
  const rows = model.rows!;
  expect(rows.find((row) => row.id === "time:head")?.trailing).toContain("At least 10 tokens");
  expect(rows.find((row) => row.id === "time:run")?.trailing).toBe("1s");
  const action = rows.find((row) => row.id === "time:run")?.action;
  expect(action).toBeDefined();
  expect(actions.run(action!)).toBe(true);
  await Promise.resolve();
  expect(revealed).toBe("turn-1");
});

test("an empty or absent journal adds no native usage section", () => {
  const empty = { totalMs: 0, tokensComplete: false, categories: [], spans: [] };
  expect(
    usageSection({ sessions: [], open: true, timeBreakdown: empty }, new NativeInfoActions(), translate),
  ).toBeUndefined();
  expect(usageSection({ sessions: [], open: true }, new NativeInfoActions(), translate)).toBeUndefined();
});
