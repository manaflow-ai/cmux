// Runs a scenario of the map (streamScenarios.ts) on the model: the simulator's rules (a)(b)(c) and the
// bubble-integrity rules (integrity.ts) at every step, and text conservation at the end. The live cases run in
// test/chat-stream-scenarios.test.ts, which has the fake acpmux.
import type { AcpmuxDirectClient, EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";
import { checkIntegrity, checkTextConserved, type IntegrityFinding } from "./integrity";
import { createSimulation } from "./run";
import type { SimScenario } from "./script";
import type { StreamScenario } from "./streamScenarios";

export type MapFinding = { rule: string; step: number; label: string; rowId: string; detail: string };

/** Each message id the records name, to the rows the reducer streamed it into. */
export function messageIndex(
  events: readonly EventRecord[],
  client: Pick<AcpmuxDirectClient, "rowsOfMessage">,
): (rowId: string) => string | undefined {
  const byRow = new Map<string, string>();
  const ids = new Set<string>();
  for (const event of events) {
    const id = event.msg?.params?.update?.messageId;
    if (typeof id === "string") ids.add(id);
  }
  for (const id of ids) for (const row of client.rowsOfMessage(id)) byRow.set(row, id);
  return (rowId) => byRow.get(rowId);
}

/** Integrity findings keyed so one that persists over many steps is reported once. */
export function dedupe(findings: MapFinding[]): MapFinding[] {
  const seen = new Set<string>();
  return findings.filter((finding) => {
    const key = `${finding.rule}|${finding.rowId}|${finding.detail}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/// The model run of `scenario` with every rule; [] when it holds.
export function runMapScenario(entry: StreamScenario, scenario: SimScenario = entry.make!()): MapFinding[] {
  const sim = createSimulation(scenario, { rowsInTraceUpTo: 0, exemptIntegrity: entry.exempt });
  const findings: MapFinding[] = [];
  const exempt = new Set(entry.exempt ?? []);
  let rows: readonly AcpmuxRow[] | undefined;
  scenario.steps.forEach((step, index) => {
    rows = sim.advance(index);
    if (!rows) return;
    sim.check(index);
    const { client } = sim.reducer();
    const turnEnded = sim.state().turnEnded;
    const seen = scenario.events.filter((event) => step.type !== "event" || event.seq <= step.seq);
    for (const finding of checkIntegrity({ rows, turnEnded, messageOf: messageIndex(seen, client) }))
      if (!exempt.has(finding.rule)) findings.push({ ...finding, step: index, label: step.label });
  });
  const result = sim.result();
  for (const violation of result.violations)
    findings.push({
      rule: violation.rule,
      step: violation.step,
      label: violation.label,
      rowId: violation.rowId,
      detail: violation.detail,
    });
  const { snapshot } = sim.reducer();
  const conserved: IntegrityFinding[] = checkTextConserved(scenario.events, snapshot?.rows ?? []);
  for (const finding of conserved) findings.push({ ...finding, step: scenario.steps.length - 1, label: "end" });
  return dedupe(findings);
}

/// The bubble-integrity checker on a recorded chat (scripts/chat-sim.ts --integrity): the integrity rules on the
/// drawn rows at every turn's end and at the last record. Cheap enough for a day of Leo's
/// NIGHTLY sessions: it shapes the rows once a turn, not once a record.
export function integrityScan(scenario: SimScenario): MapFinding[] {
  const sim = createSimulation(scenario, { rowsInTraceUpTo: 0 });
  const findings: MapFinding[] = [];
  const bySeq = new Map(scenario.events.map((event) => [event.seq, event]));
  const last = scenario.steps.length - 1;
  scenario.steps.forEach((step, index) => {
    const rows = sim.advance(index);
    const ends = step.type === "event" && bySeq.get(step.seq)?.kind === "turn_result";
    if (!rows || (!ends && index !== last)) return;
    const { client } = sim.reducer();
    const seen = scenario.events.filter((event) => step.type !== "event" || event.seq <= step.seq);
    for (const finding of checkIntegrity({
      rows,
      turnEnded: ends || sim.state().turnEnded,
      messageOf: messageIndex(seen, client),
    }))
      findings.push({ ...finding, step: index, label: step.label });
  });
  // No text conservation here: a recorded chat sheds, hides and re-reads rows by design (a cut of a long log
  // starts mid-turn), so only the scripted and live cases hold the sent text to the rows.
  return dedupe(findings);
}
