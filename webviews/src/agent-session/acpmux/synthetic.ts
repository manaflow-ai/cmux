import type { AcpmuxRow } from "./model";

/**
 * A deterministic synthetic transcript for scroll and layout measurements, the
 * port of the native pane's `AcpmuxSyntheticTranscript`: `count / 3` turns, each
 * a user message, an assistant answer of 1-5 sentences (a three-item list when
 * turn % 3 == 0, a code block when turn % 7 == 0) and a turn summary in place
 * of the native turn end, so the row mix and heights resemble a real session.
 * `short`: one-line prompts answered "ok N", as the Codex reference chat the thread
 * minimap's density is compared with (#20560).
 */
export function syntheticRows(count: number, mix: "mixed" | "short" = "mixed"): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  let seq = 0;
  const next = (row: Omit<AcpmuxRow, "version" | "at">) => {
    seq += 1;
    rows.push({ ...row, version: 1, at: seq * 1_000 });
  };
  const turns = Math.max(1, Math.floor(count / 3));
  for (let turn = 0; turn < turns; turn += 1) {
    if (mix === "short") {
      next({ id: `synthetic-user-${turn}`, kind: "user", text: `Reply with only the word ok and the number ${turn}.` });
      next({ id: `synthetic-assistant-${turn}`, kind: "assistant", text: `ok ${turn}` });
      next({ id: `synthetic-end-${turn}`, kind: "turnSummary", durationMs: 1_000, toolCount: 0, status: "completed" });
      continue;
    }
    next({
      id: `synthetic-user-${turn}`,
      kind: "user",
      text: `Question ${turn}: how should the transcript handle item ${turn % 97}?`,
    });
    let answer = `Answer ${turn}. ` + "This sentence adds some width to the paragraph. ".repeat(1 + (turn % 5));
    if (turn % 3 === 0) answer += "\n\n- first point\n- second point\n- third point";
    if (turn % 7 === 0) answer += `\n\n\`\`\`swift\nlet value = ${turn}\nprint(value)\n\`\`\``;
    next({ id: `synthetic-assistant-${turn}`, kind: "assistant", text: answer });
    next({ id: `synthetic-end-${turn}`, kind: "turnSummary", durationMs: 1_000, toolCount: 0, status: "completed" });
  }
  return rows;
}

/// A long completed turn with separate settled rows under its open Worked-for disclosure. The
/// resize bench uses it to keep the disclosure-control scan on the measured path.
export function workedResizeRows(count: number): AcpmuxRow[] {
  const rows: AcpmuxRow[] = syntheticRows(Math.floor(count / 2));
  const baseAt = (rows.length + 1) * 1_000;
  rows.push({
    id: "worked-resize-user",
    version: 1,
    at: baseAt,
    kind: "user",
    text: "Keep working through this long task.",
  });
  const steps = Math.max(1, count - rows.length - 3);
  for (let index = 0; index < steps; index += 1) {
    const id = `worked-resize-${index}`;
    rows.push(
      {
        id: `${id}-activity`,
        version: 1,
        at: baseAt + (index + 1) * 1_000,
        kind: "activity",
        toolCount: 1,
        items: [
          {
            kind: "tool",
            text: `echo ${index}`,
            tool: { id, title: `echo ${index}`, kind: "execute", status: "completed", command: `echo ${index}` },
          },
        ],
      },
      {
        id: `${id}-commentary`,
        version: 1,
        at: baseAt + (index + 1) * 1_000 + 500,
        kind: "assistant",
        assistantPhase: "commentary",
        text: `Progress update ${index}: the task is still moving through its settled work.`,
      },
    );
  }
  rows.push(
    {
      id: "worked-resize-answer",
      version: 1,
      at: baseAt + (steps + 1) * 1_000,
      kind: "assistant",
      text: "The long task is complete.",
    },
    {
      id: "worked-resize-summary",
      version: 1,
      at: baseAt + (steps + 2) * 1_000,
      kind: "turnSummary",
      durationMs: steps * 1_000,
      toolCount: steps,
      status: "completed",
    },
  );
  return rows;
}
