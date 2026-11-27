// What became of an agent's question, read back from acpmux's `permission_decision` record: the
// transcript keeps it once the card goes (direct.ts, the `questionRecord` row), so a reload shows
// what was chosen, or that nothing was. The inverse of model.ts `reply`, per harness: Claude Code's
// answers come keyed by question text, one comma-separated string per question; Codex's by
// question id, `{answers: [label]}`; an ACP ask's answer is the permission option chosen.
import { plainText } from "./inlineText";
import {
  questionSummary,
  type AgentQuestion,
  type Answer,
  type CancelReason,
  type Item,
  type Respondent,
  type Selection,
  type State,
} from "./model";

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

/// Claude Code answers one string per question; a multi-select joins its choices with ", ". A
/// single-select answer is one choice whole, its Other text included. A multi-select is read from
/// the front, the longest label that fits first, so a label with a comma in it stays one choice.
function claudeLabels(item: Item, value: Json): string[] {
  if (typeof value !== "string") return [];
  const answer = value.trim();
  if (!item.multiSelect) return [answer];
  const labels = [...new Set(item.options.map((option) => option.label))].sort((a, b) => b.length - a.length);
  const read: string[] = [];
  let rest = answer;
  while (rest) {
    const label = labels.find((candidate) => rest === candidate || rest.startsWith(`${candidate}, `));
    // Other text comes last (model.ts `labels`): what no label starts is that text, whole.
    const taken = label ?? rest;
    read.push(taken);
    rest = rest.slice(taken.length).replace(/^, /, "");
  }
  return read;
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

/// Who answered, from the record's `answeredBy`: a session above this one names itself
/// (`{session, name}`, acpmux `hub/subsession_answer.rs`). The person's app answering for another
/// of their devices (`{device, feedItem}`, `AcpmuxPermissionFeedBridge.swift`, acpmux
/// `hub/person.rs` `answered_by`) is a remote answer: its `device` is an install id, not a name, so
/// none is shown. A person's answer here names no one.
function respondentOf(answeredBy: Json): Respondent | undefined {
  if (!isObject(answeredBy)) return undefined;
  if (typeof answeredBy.session === "string") {
    const name = typeof answeredBy.name === "string" && answeredBy.name ? answeredBy.name : answeredBy.session;
    return { displayName: name, isRemote: false, isSession: true };
  }
  if (typeof answeredBy.device === "string" && answeredBy.device) return { isRemote: true };
  return undefined;
}

/// Why an unanswered ask ended (`CancelReason`): its reject option chosen is a Skip; a bare cancel on
/// an ask that has a reject option is acpmux's own (a stopped turn), since Skip would have sent that
/// option. Without a reject option a Skip is a bare cancel too, so nothing is said.
function cancelReason(question: AgentQuestion, outcome: Json): CancelReason | undefined {
  if (!isObject(outcome)) return undefined;
  const reject = question.source.rejectOption;
  if (reject === undefined) return undefined;
  if (outcome.outcome === "selected" && outcome.optionId === reject) return "skipped";
  if (outcome.outcome === "cancelled") return "stopped";
  return undefined;
}

/// `question` as its decision left it: answered with what was chosen (and by whom, when a session
/// above this one answered), else cancelled.
export function decidedQuestion(question: AgentQuestion, outcome: Json, answeredBy?: Json): AgentQuestion {
  const answer = answerFromOutcome(question, outcome);
  const respondent = respondentOf(answeredBy);
  const answered = answer && respondent ? { ...answer, respondent } : answer;
  const reason = answered ? undefined : cancelReason(question, outcome);
  const state: State = answered
    ? { kind: "answered", answer: answered }
    : reason
      ? { kind: "cancelled", reason }
      : { kind: "cancelled" };
  return { ...question, state };
}

/// The arguments of the line an unanswered ask leaves (`cancelledKey`): the question without its
/// inline marks, the same in the card and in what Copy reads.
export const cancelledArgs = (question: AgentQuestion): { prompt: string } => ({
  prompt: plainText(questionSummary(question)),
});
