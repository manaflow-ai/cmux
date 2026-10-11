import type { AcpmuxRow } from "./model";

/**
 * A deterministic synthetic transcript for scroll and layout measurements, the
 * port of the native pane's `AcpmuxSyntheticTranscript`: `count / 3` turns, each
 * a user message, an assistant answer of 1-5 sentences (a three-item list when
 * turn % 3 == 0, a code block when turn % 7 == 0) and a turn summary in place
 * of the native turn end, so the row mix and heights resemble a real session.
 */
export function syntheticRows(count: number): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  let seq = 0;
  const next = (row: Omit<AcpmuxRow, "version" | "at">) => {
    seq += 1;
    rows.push({ ...row, version: 1, at: seq * 1_000 });
  };
  const turns = Math.max(1, Math.floor(count / 3));
  for (let turn = 0; turn < turns; turn += 1) {
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
