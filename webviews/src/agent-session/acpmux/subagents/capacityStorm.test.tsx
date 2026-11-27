// l10n-allow-file: test fixture names and errors, not shipped UI.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { SubagentGroupHeader } from "./SubagentGroup";
import { SubagentStartedLine } from "./SubagentStartedLine";
import { SubagentFold } from "./subagentFold";
import { withSubagentRows } from "./subagentRows";
import { withSubagentLines } from "./runningTray";

test("eleven capacity holds form one calm row in both layouts; real failures and recovery remain visible", () => {
  const fold = new SubagentFold();
  let seq = 0;
  const update = (id: string, fields: Record<string, unknown>, spawn = false) => {
    seq += 1;
    const change = { sessionUpdate: spawn ? "subagent_spawned" : "subagent_state_update" };
    fold.reduce(
      {
        seq,
        at: seq * 1000,
        msg: {
          method: "session/update",
          params: {
            update: change,
            _meta: { acpmux: { subagents: [{ id, ...fields }] } },
          },
        },
      },
      change,
    );
  };
  for (let index = 0; index < 11; index += 1) {
    const id = `helper-${index}`;
    update(id, { parent: null, name: id }, true);
    update(id, {
      state: "failed",
      error: "429 no non-exhausted claude accounts available",
      capacityWait: { reason: "capacity", resumesAt: Date.now() + 180_000 },
    });
  }
  const group = (): AcpmuxRow => ({
    id: "helpers",
    kind: "subagents",
    version: seq,
    at: 1000,
    subagents: [...fold.all()],
  });
  const markup = (row: AcpmuxRow) =>
    renderToStaticMarkup(<SubagentGroupHeader row={row} expanded onToggle={() => {}} />);
  expect(markup(group())).toContain("11 helpers paused");
  expect(markup(group())).not.toContain('data-state="failed"');
  expect(withSubagentRows([group()], new Set(["helpers"]))).toHaveLength(1);
  const cache = new Map();
  const lines = withSubagentLines([group()], cache);
  expect(lines).toHaveLength(1);
  expect(lines[0]!.kind).toBe("subagentStarted");
  expect(renderToStaticMarkup(<SubagentStartedLine row={lines[0]!} />)).toContain("11 helpers paused");

  update("helper-0", { state: "failed", capacityWait: null, error: "401 unauthorized" });
  expect(markup(group())).toContain("10 helpers paused");
  expect(markup(group())).toContain("1 failed");
  const mixed = withSubagentLines([group()], cache);
  expect(mixed.filter((row) => row.kind === "subagentDone").map((row) => row.subagents?.[0]?.error)).toEqual([
    "401 unauthorized",
  ]);
  expect(withSubagentRows([group()], new Set(["helpers"]))).toHaveLength(2);

  for (let index = 1; index < 11; index += 1) {
    update(`helper-${index}`, { state: "running" });
    update(`helper-${index}`, { state: "completed" });
  }
  expect(markup(group())).not.toContain("paused");
  expect(withSubagentLines([group()], cache).filter((row) => row.kind === "subagentDone")).toHaveLength(11);
});
