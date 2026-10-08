// A question an agent asks a person, independent of the harness that asked. This is a 1:1 port
// of the Swift package Packages/Shared/CmuxAgentQuestion (AgentQuestion.swift,
// AgentQuestion+Permission.swift, AgentQuestionAnswer.swift); both ports read the same JSON
// fixtures in its Fixtures/ directory, and the JSON shape of every type here is the Swift
// Codable shape (absent optional fields are omitted, never null).

/// The asking harness. It decides the answer's wire shape: `claude` answers are keyed by
/// question text, `codex` by question id, `acp` by the chosen permission option, and the
/// `chief` (asking in a Home conversation) answers like Claude.
export type Harness = "claude" | "codex" | "acp" | "chief";
const HARNESSES: readonly Harness[] = ["claude", "codex", "acp", "chief"];

/// Who asked, and where the answer goes.
export type Source = {
  harness: Harness;
  /// acpmux session id (the agent tab or the Chief's session).
  session: string;
  /// acpmux permission id; the answer goes to `_acpmux/permission_respond`.
  permission?: string;
  /// The harness's tool call id, when it has one.
  toolCall?: string;
  /// The display name of the asking agent ("Claude Code", "Chief").
  agentName?: string;
  /// The permission option that submits answers (`allow_once`).
  answerOption?: string;
  /// The permission option that declines the ask (`reject_once`).
  rejectOption?: string;
};

/// Content shown beside the options while one is highlighted (a code sample, a layout sketch).
export type Preview = { text: string; format: "markdown" | "monospace" };

export type Option = {
  /// Stable within its item: the harness's option id, else the label.
  id: string;
  label: string;
  detail?: string;
  preview?: Preview;
};

/// One question of an ask.
export type Item = {
  /// Stable within the ask: the harness's id, else `q<index>`.
  id: string;
  /// A short label shown as a chip above the prompt ("Auth method").
  header?: string;
  prompt: string;
  options: Option[];
  multiSelect: boolean;
  /// Whether the person may type an answer that is not an option.
  allowsOther: boolean;
};

/// What was chosen for one item.
export type Selection = {
  /// Option ids in the order the item lists them.
  optionIDs: string[];
  /// Free text typed into "Other", trimmed; absent when empty.
  other?: string;
};

/// Who answered. The owner stamps it from the connection, never from the client's claim.
export type Respondent = {
  /// Conversation participant (`user_local`, `user_<id>`).
  participant?: string;
  displayName?: string;
  /// The answering device's name ("Lawrence's iPhone").
  device?: string;
  /// True when the answer came through the remote relay from a paired device.
  isRemote: boolean;
};

/// A person's answer, harness-neutral: one selection per item id.
export type Answer = {
  selections: Record<string, Selection>;
  respondent?: Respondent;
  /// Milliseconds since 1970, stamped by the owner.
  answeredAtMs?: number;
};

/// Where the ask stands. Only the owner moves it out of `pending`; clients render it.
export type State = { kind: "pending" } | { kind: "answered"; answer: Answer } | { kind: "cancelled" };

/// One ask: one to four items, the source that decides the answer's shape, and its state.
export type AgentQuestion = {
  /// The acpmux permission id, or the conversation part id for a question posted in Home.
  id: string;
  source: Source;
  items: Item[];
  state: State;
};

/// Why an answer cannot be sent.
export type Problem =
  | { kind: "unanswered"; item: string }
  | { kind: "tooManyChoices"; item: string }
  | { kind: "unknownOption"; item: string; option: string }
  | { kind: "otherNotAllowed"; item: string }
  | { kind: "unknownItem"; item: string }
  | { kind: "notPending" };

/// Thrown by `reply` with the first problem of an incomplete or invalid answer.
export class QuestionProblemError extends Error {
  constructor(readonly problem: Problem) {
    super(`agent question answer refused: ${problem.kind}`);
    this.name = "QuestionProblemError";
  }
}

/// What a client sends to `_acpmux/permission_respond` to answer a question.
export type QuestionReply = {
  session: string;
  permissionId: string;
  /// Absent cancels the request.
  optionId?: string;
  /// The harness-shaped answers acpmux puts into the tool's input.
  answers?: Record<string, unknown>;
};

// MARK: JSON reading (AgentQuestionJSON)

type Json = unknown;
type JsonObject = Record<string, Json>;

const isObject = (value: Json): value is JsonObject =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const field = (value: Json, key: string): Json => (isObject(value) ? value[key] : undefined);
/// Follows a `/`-separated path of object keys; undefined when a key is missing.
const at = (value: Json, path: string): Json =>
  path.split("/").reduce<Json>((current, key) => field(current, key), value);
const string = (value: Json): string | undefined => (typeof value === "string" ? value : undefined);
/// A non-empty string after trimming whitespace.
const text = (value: Json): string | undefined => {
  const trimmed = string(value)?.trim();
  return trimmed ? trimmed : undefined;
};
const bool = (value: Json): boolean | undefined => (typeof value === "boolean" ? value : undefined);
const array = (value: Json): Json[] | undefined => (Array.isArray(value) ? value : undefined);

/// Copies `fields` without its undefined entries, so an absent optional is absent (Codable shape).
function compact<T extends object>(fields: T): T {
  return Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== undefined)) as T;
}

// MARK: Construction helpers

/// A selection with its Other text trimmed and dropped when empty (Swift `Selection.init`).
export function selection(optionIDs: string[] = [], other?: string): Selection {
  const trimmed = other?.trim();
  return compact({ optionIDs, other: trimmed ? trimmed : undefined });
}

const selectionIsEmpty = (value: Selection | undefined) => !value || (value.optionIDs.length === 0 && !value.other);

/// True when at least one option carries a preview: the card then shows the highlighted
/// option's preview beside the list.
export const hasPreviews = (item: Item): boolean => item.options.some((option) => option.preview !== undefined);

export const isPending = (question: AgentQuestion): boolean => question.state.kind === "pending";

/// The first item's prompt, for notifications, previews and search.
export const questionSummary = (question: AgentQuestion): string => question.items[0]?.prompt ?? "";

// MARK: Mapping a permission request (AgentQuestion+Permission.swift)

/// An acpmux `permission_request` record: the ACP `session/request_permission` params plus
/// acpmux's permission id and the session it belongs to.
export type PermissionRecord = { permissionId: string; session: string; request: Json };

type PermissionOption = { id: string; name: string; kind?: string };

function permissionOptions(request: Json): PermissionOption[] {
  return (array(field(request, "options")) ?? []).flatMap((option) => {
    const id = text(field(option, "optionId"));
    if (!id) return [];
    return [{ id, name: text(field(option, "name")) ?? id, kind: string(field(option, "kind")) }];
  });
}

/// Option ids must be unique within an item: a repeated label gets `#2`, `#3`.
function uniqueOptions(options: Option[]): Option[] {
  const seen = new Map<string, number>();
  return options.map((option) => {
    const count = (seen.get(option.id) ?? 0) + 1;
    seen.set(option.id, count);
    return count > 1 ? { ...option, id: `${option.id}#${count}` } : option;
  });
}

/// Claude Code: `{question, header, options: [{label, description, preview}], multiSelect}`.
/// Answers are keyed by question text, so items keep positional ids.
function claudeItem(value: Json, index: number): Item | undefined {
  const prompt = text(field(value, "question"));
  if (prompt === undefined) return undefined;
  const options = uniqueOptions(
    (array(field(value, "options")) ?? []).flatMap((option): Option[] => {
      const label = text(field(option, "label"));
      if (label === undefined) return [];
      const preview = text(field(option, "preview"));
      return [
        compact({
          id: label,
          label,
          detail: text(field(option, "description")),
          preview: preview === undefined ? undefined : { text: preview, format: "monospace" as const },
        }),
      ];
    }),
  );
  return compact({
    id: `q${index}`,
    header: text(field(value, "header")),
    prompt,
    options,
    multiSelect: bool(field(value, "multiSelect")) ?? false,
    allowsOther: true,
  });
}

/// Codex: `{id, header, question, isOther, options: [{label, description}] | null}`.
/// Answers are keyed by `id`; a question with no options takes free text.
function codexItem(value: Json, index: number): Item | undefined {
  const prompt = text(field(value, "question"));
  if (prompt === undefined) return undefined;
  const options = uniqueOptions(
    (array(field(value, "options")) ?? []).flatMap((option): Option[] => {
      const label = text(field(option, "label"));
      return label === undefined ? [] : [compact({ id: label, label, detail: text(field(option, "description")) })];
    }),
  );
  const allowsOther = bool(field(value, "isOther")) ?? options.length === 0;
  return compact({
    id: text(field(value, "id")) ?? `q${index}`,
    header: text(field(value, "header")),
    prompt,
    options,
    multiSelect: bool(field(value, "multiSelect")) ?? false,
    allowsOther: allowsOther || options.length === 0,
  });
}

/// Decodes one `Option` in its Codable form; undefined when a required field is missing.
function decodeOption(value: Json): Option | undefined {
  const id = string(field(value, "id"));
  const label = string(field(value, "label"));
  const detail = field(value, "detail");
  const preview = field(value, "preview");
  if (id === undefined || label === undefined) return undefined;
  if (detail !== undefined && detail !== null && typeof detail !== "string") return undefined;
  let decodedPreview: Preview | undefined;
  if (preview !== undefined && preview !== null) {
    const previewText = string(field(preview, "text"));
    const format = field(preview, "format");
    if (previewText === undefined || (format !== "markdown" && format !== "monospace")) return undefined;
    decodedPreview = { text: previewText, format };
  }
  return compact({ id, label, detail: string(detail), preview: decodedPreview });
}

/// Decodes one `Item` in its Codable form: `multiSelect` defaults to false and `allowsOther` to
/// true when absent, so other writers (the daemon, the web gallery) may omit them.
function decodeItem(value: Json): Item | undefined {
  const id = string(field(value, "id"));
  const prompt = string(field(value, "prompt"));
  const header = field(value, "header");
  const rawOptions = field(value, "options");
  const multiSelect = field(value, "multiSelect");
  const allowsOther = field(value, "allowsOther");
  if (id === undefined || prompt === undefined) return undefined;
  if (header !== undefined && header !== null && typeof header !== "string") return undefined;
  if (rawOptions !== undefined && rawOptions !== null && !Array.isArray(rawOptions)) return undefined;
  if (multiSelect !== undefined && multiSelect !== null && typeof multiSelect !== "boolean") return undefined;
  if (allowsOther !== undefined && allowsOther !== null && typeof allowsOther !== "boolean") return undefined;
  const options: Option[] = [];
  for (const option of array(rawOptions) ?? []) {
    const decoded = decodeOption(option);
    if (!decoded) return undefined;
    options.push(decoded);
  }
  return compact({
    id,
    header: string(header),
    prompt,
    options,
    multiSelect: bool(multiSelect) ?? false,
    allowsOther: bool(allowsOther) ?? true,
  });
}

/// The daemon's normalized shape: `{harness, agent, items: [Item]}`. All items decode or none.
function normalizedItems(value: Json): Item[] | undefined {
  const items = array(field(value, "items"));
  if (!items) return undefined;
  const decoded: Item[] = [];
  for (const item of items) {
    const next = decodeItem(item);
    if (!next) return undefined;
    decoded.push(next);
  }
  return decoded;
}

/// Maps an acpmux `permission_request` record to a question, or undefined when the request is
/// an ordinary tool permission.
///
/// Precedence: the daemon's normalized `toolCall._meta.acpmux.question` when present, then
/// Claude Code's AskUserQuestion input, then a Codex user-input request, then any request
/// marked interactive (its permission options become the choices).
export function questionFromPermission(record: PermissionRecord): AgentQuestion | undefined {
  const { permissionId, session, request } = record;
  const toolCall = field(request, "toolCall");
  const input = field(toolCall, "rawInput");
  const options = permissionOptions(request);
  const base = {
    session,
    permission: permissionId,
    toolCall: string(field(toolCall, "toolCallId")),
    answerOption: options.find((option) => option.kind === "allow_once")?.id,
    rejectOption: options.find((option) => option.kind === "reject_once")?.id,
  };
  const question = (harness: Harness, agentName: string | undefined, items: Item[]): AgentQuestion => ({
    id: permissionId,
    source: compact({ harness, ...base, agentName }),
    items,
    state: { kind: "pending" },
  });

  const normalized = at(toolCall, "_meta/acpmux/question");
  if (normalized !== undefined) {
    const items = normalizedItems(normalized);
    if (items && items.length > 0) {
      const named = string(field(normalized, "harness"));
      const harness = HARNESSES.find((candidate) => candidate === named) ?? "acp";
      return question(harness, text(field(normalized, "agent")), items);
    }
  }
  const claudeTool = string(at(toolCall, "_meta/claude/tool"));
  const questions = array(field(input, "questions")) ?? [];
  const isCodex =
    at(toolCall, "_meta/codex") !== undefined || questions.some((value) => text(field(value, "id")) !== undefined);
  if (claudeTool === "AskUserQuestion" || (questions.length > 0 && !isCodex)) {
    const items = questions.flatMap((value, index) => claudeItem(value, index) ?? []);
    return items.length > 0 ? question("claude", "Claude Code", items) : undefined;
  }
  if (isCodex) {
    const items = questions.flatMap((value, index) => codexItem(value, index) ?? []);
    return items.length > 0 ? question("codex", "Codex", items) : undefined;
  }
  const interactive =
    bool(at(toolCall, "_meta/acpmux/interactive")) === true || bool(at(toolCall, "_meta/claude/interactive")) === true;
  if (!interactive || options.length === 0) return undefined;
  const prompt = text(field(toolCall, "title")) ?? "";
  const choices = options.map((option) => ({ id: option.id, label: option.name }));
  return question("acp", undefined, [{ id: "q0", prompt, options: choices, multiSelect: false, allowsOther: false }]);
}

// MARK: Answers (AgentQuestionAnswer.swift)

/// Checks `answer` against its question. An item is answered by exactly one option or Other
/// text (single select), or by one or more options plus optional Other text (multi-select).
export function answerProblems(question: AgentQuestion, answer: Answer): Problem[] {
  if (!isPending(question)) return [{ kind: "notPending" }];
  const problems: Problem[] = Object.keys(answer.selections)
    .filter((key) => !question.items.some((item) => item.id === key))
    .sort()
    .map((item) => ({ kind: "unknownItem", item }));
  for (const item of question.items) {
    const chosen = answer.selections[item.id] ?? selection();
    if (selectionIsEmpty(chosen)) {
      problems.push({ kind: "unanswered", item: item.id });
      continue;
    }
    for (const option of chosen.optionIDs)
      if (!item.options.some((candidate) => candidate.id === option))
        problems.push({ kind: "unknownOption", item: item.id, option });
    if (chosen.other && !item.allowsOther) problems.push({ kind: "otherNotAllowed", item: item.id });
    if (!item.multiSelect && chosen.optionIDs.length + (chosen.other ? 1 : 0) > 1)
      problems.push({ kind: "tooManyChoices", item: item.id });
  }
  return problems;
}

/// The chosen option labels in the item's order, then the Other text.
function labels(item: Item, chosen: Selection | undefined): string[] {
  if (!chosen) return [];
  const picked = item.options.filter((option) => chosen.optionIDs.includes(option.id)).map((option) => option.label);
  return chosen.other ? [...picked, chosen.other] : picked;
}

/// The reply that submits `answer`, in the asking harness's shape. Throws a
/// `QuestionProblemError` with the first problem when the answer is incomplete or invalid.
export function reply(question: AgentQuestion, answer: Answer): QuestionReply {
  const problem = answerProblems(question, answer)[0];
  if (problem) throw new QuestionProblemError(problem);
  const { session, permission, harness, answerOption } = question.source;
  if (permission === undefined) throw new QuestionProblemError({ kind: "notPending" });
  switch (harness) {
    case "acp": {
      // One item; its option ids are the permission options.
      const optionId = answer.selections[question.items[0]!.id]?.optionIDs[0];
      return compact({ session, permissionId: permission, optionId });
    }
    case "claude":
    case "chief": {
      // Claude Code reads `answers` keyed by question text; several choices are one
      // comma-separated string.
      const answers: Record<string, string> = {};
      for (const item of question.items) answers[item.prompt] = labels(item, answer.selections[item.id]).join(", ");
      return { session, permissionId: permission, optionId: answerOption ?? "allow_once", answers };
    }
    case "codex": {
      // Codex reads `{id: {answers: [String]}}`.
      const answers: Record<string, { answers: string[] }> = {};
      for (const item of question.items) answers[item.id] = { answers: labels(item, answer.selections[item.id]) };
      return { session, permissionId: permission, optionId: answerOption ?? "allow_once", answers };
    }
  }
}

/// The reply that declines the question: the harness's reject option, else a cancel. Never an allow.
export function declineReply(question: AgentQuestion): QuestionReply | undefined {
  const { session, permission, rejectOption } = question.source;
  if (permission === undefined) return undefined;
  return compact({ session, permissionId: permission, optionId: rejectOption });
}

/// The `_acpmux/permission_respond` params of a reply.
export function replyParams(sent: QuestionReply): Record<string, unknown> {
  return compact({
    sessionId: sent.session,
    permissionId: sent.permissionId,
    optionId: sent.optionId,
    answers: sent.answers,
  });
}

/// The chosen labels of one item, joined: "OAuth, Passkeys".
export const itemAnswerText = (item: Item, answer: Answer): string =>
  labels(item, answer.selections[item.id]).join(", ");

/// One line per item for the answered card and notifications: "Auth method: OAuth, Passkeys".
export function summaryLines(question: AgentQuestion, answer: Answer): string[] {
  return question.items.map((item) => `${item.header ?? item.prompt}: ${itemAnswerText(item, answer)}`);
}
