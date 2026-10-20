// What became of an agent's question, read back from acpmux's `permission_decision` record: the
// transcript keeps it once the card goes (direct.ts, the `questionRecord` row), so a reload shows
// what was chosen, or that nothing was. The inverse of model.ts `reply`, per harness: Claude Code's
// answers come keyed by question text, one comma-separated string per question; Codex's by
// question id, `{answers: [label]}`; an ACP ask's answer is the permission option chosen.
import type { AgentQuestion, Answer, Item, Selection } from "./model";

/// The transcript row of a decided question; it draws under a finished turn's fold line, not in it
/// (conversation/turns.ts `staysOut`).
export const QUESTION_RECORD = "questionRecord";

type Json = unknown;
type JsonObject = Record<string, Json>;
const isObject = (value: Json): value is JsonObject =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/// Option ids by label, the first option of a repeated label winning (model.ts `uniqueOptions`).
function byLabel(item: Item): Map<string, string> {
  const ids = new Map<string, string>();
  for (const option of item.options) if (!ids.has(option.label)) ids.set(option.label, option.id);
  return ids;
}

/// The selection the labels name: each option's id, the rest as Other text. Absent when empty.
function selectionOf(item: Item, labels: string[]): Selection | undefined {
  const ids = byLabel(item);
  const optionIDs: string[] = [];
  const other: string[] = [];
  for (const label of labels.map((value) => value.trim()).filter(Boolean)) {
    const id = ids.get(label);
    if (id !== undefined && !optionIDs.includes(id)) optionIDs.push(id);
    else if (id === undefined) other.push(label);
  }
  if (optionIDs.length === 0 && other.length === 0) return undefined;
  // The order the item lists its options, as the card keeps it.
  const order = item.options.map((option) => option.id);
  optionIDs.sort((a, b) => order.indexOf(a) - order.indexOf(b));
  return other.length > 0 ? { optionIDs, other: other.join(", ") } : { optionIDs };
}

/// Claude Code joins several choices with ", ". A whole string that is one label stays one,
/// even with a comma in it.
function claudeLabels(item: Item, value: Json): string[] {
  if (typeof value !== "string") return [];
  if (byLabel(item).has(value.trim())) return [value.trim()];
  return value.split(", ");
}

function codexLabels(value: Json): string[] {
  const answers = isObject(value) ? value.answers : undefined;
  return Array.isArray(answers) ? answers.filter((entry): entry is string => typeof entry === "string") : [];
}

/// The answer an outcome carries, or undefined when the question was cancelled or declined.
export function answerFromOutcome(question: AgentQuestion, outcome: Json): Answer | undefined {
  if (!isObject(outcome) || outcome.outcome !== "selected") return undefined;
  const optionId = typeof outcome.optionId === "string" ? outcome.optionId : undefined;
  const { harness, rejectOption } = question.source;
  const selections: Record<string, Selection> = {};
  if (harness === "acp") {
    // One item; its options are the permission options, the one picked the answer.
    const item = question.items[0];
    if (!item || optionId === undefined || !item.options.some((option) => option.id === optionId)) return undefined;
    selections[item.id] = { optionIDs: [optionId] };
  } else {
    if (optionId !== undefined && optionId === rejectOption) return undefined;
    const meta = isObject(outcome._meta) ? outcome._meta : undefined;
    const input = meta && isObject(meta.updatedInput) ? meta.updatedInput : undefined;
    const answers = input && isObject(input.answers) ? input.answers : undefined;
    if (!answers) return undefined;
    for (const item of question.items) {
      const labels = harness === "codex" ? codexLabels(answers[item.id]) : claudeLabels(item, answers[item.prompt]);
      const chosen = selectionOf(item, labels);
      if (chosen) selections[item.id] = chosen;
    }
    if (Object.keys(selections).length === 0) return undefined;
  }
  return { selections };
}

/// `question` as its decision left it: answered with what was chosen, else cancelled.
export function decidedQuestion(question: AgentQuestion, outcome: Json): AgentQuestion {
  const answer = answerFromOutcome(question, outcome);
  return { ...question, state: answer ? { kind: "answered", answer } : { kind: "cancelled" } };
}
