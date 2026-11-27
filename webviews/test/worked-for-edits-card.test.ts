// The edited-files card under a finished turn's answer holds the turn's edits, never the rest of the
// work. A harness that sends a whole turn's calls with no message between them (Antigravity) gives
// one activity row of reads, commands, thoughts and edits; the card took that row whole, so every
// call of the turn drew beside the closed "Worked for", under the answer.
import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";

let n = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: fields.id ?? `${kind}-${(n += 1)}`,
  version: 1,
  at: (n += 1) * 1000,
  kind,
  ...fields,
});
const tool = (id: string, title: string, kind: string, fields: Record<string, unknown> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: title,
  tool: { id, title, kind, status: "completed", ...fields },
});
const thought: AcpmuxActivity = { kind: "thought", text: "Checking the composer border on main." };

const turn = (): AcpmuxRow[] => {
  const items = [
    thought,
    tool("read-1", "Read composerStates.css", "read", { locations: [{ path: "/repo/composerStates.css" }] }),
    tool("run-1", "git log -n 15", "execute", { command: "git log -n 15", output: "ok\n" }),
    tool("edit-1", "Edit lab.html", "edit", {
      locations: [{ path: "/repo/lab.html" }],
      diffs: [{ path: "/repo/lab.html", oldText: "border: 1px", newText: "border: 0" }],
    }),
    tool("read-2", "Read lab.html", "read", { locations: [{ path: "/repo/lab.html" }] }),
  ];
  return [
    row("user", { id: "prompt", text: "use the borderless composer" }),
    row("activity", { id: "work", items, toolCount: 4 }),
    row("assistant", { id: "answer", text: "Updated lab.html to the borderless composer." }),
    row("turnSummary", { id: "summary", status: "completed", toolCount: 4, durationMs: 601_000 } as Partial<AcpmuxRow>),
  ];
};

for (const family of ["antigravity", "codex", "claude"]) {
  test(`${family}: a closed Worked for keeps a mixed row's reads and commands; the card under the answer lists its edit alone`, () => {
    const drawn = turnView(turn(), new Set(), { agentFamily: family }).filter((r) => r.kind !== "date");
    const worked = drawn.findIndex((r) => r.kind === WORKED);
    expect(worked).toBeGreaterThanOrEqual(0);
    expect(drawn[worked]!.foldOpen).toBe(false);
    const below = drawn.slice(worked + 1);
    const calls = below.flatMap((r) => (r.items ?? []).flatMap((item) => (item.tool ? [item.tool.id] : [])));
    expect(calls).toEqual(["edit-1"]);
    expect(below.flatMap((r) => r.items ?? []).some((item) => item.kind === "thought")).toBe(false);
    const card = below.find((r) => r.kind === "activity")!;
    expect(card.toolCount).toBe(1);
  });
}

test("a call of another kind that carries a diff stays in the card, so Undo restores the file from its first diff", () => {
  const rows = turn();
  const work = rows[1]!;
  const patch = tool("patch-0", "apply_patch", "other", {
    diffs: [{ path: "/repo/lab.html", oldText: "border: 2px", newText: "border: 1px" }],
  });
  rows[1] = { ...work, items: [patch, ...work.items!], toolCount: 5 };
  const drawn = turnView(rows, new Set(), { agentFamily: "antigravity" }).filter((r) => r.kind !== "date");
  const below = drawn.slice(drawn.findIndex((r) => r.kind === WORKED) + 1);
  const calls = below.flatMap((r) => (r.items ?? []).flatMap((item) => (item.tool ? [item.tool.id] : [])));
  expect(calls).toEqual(["patch-0", "edit-1"]);
});
