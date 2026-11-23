// The questions the composer hat holds (HatQuestions.tsx): every ask waiting on the person in this
// chat, one place to step through them and answer with a click. Leo, 2026-11-07: "the composer hat
// can become a dual thing where you can go through it and, like, click left and right through things
// and be able to answer things as they come". Nothing here is a store of its own: each question is
// read from what the pane already has, so it leaves the hat the moment that source says it is over.
//
// Three sources, in this order:
// - the chat's own questions (AskUserQuestion, a Codex user-input request, an MCP elicitation): the
//   permissions acpmux holds open for it (model.ts `AcpmuxPermission.question`). They block the
//   agent's turn, so they come first. The one the card under the hat shows stays the card's to
//   answer (arrows, number keys, Other, Skip); the hat points to it and answers the rest in a click.
// - the tagged ask the chat's last turn ended on (conversation/nextStepAsk.ts, `[physical] Can you
//   ...?`): the transcript's next-step card, while no prompt of the person's followed it.
// - the questions of the chats this one started (needsYou/jumpPillModel.ts `pillAsks`): answered in the
//   hat as their own card would answer them, a choice or a typed answer, which the host sends for
//   the chat this pane does not show (homeInboxModel.ts `replyElsewhere`). Leo, 2026-11-10, of one
//   he could only open: "this is unusable to respond to i necessarily have to open... this is bad ui".
//
// Relevance fade (Leo: "what happens if they respond to it in another way, right? ... the question
// fade from relevance is a thing that needs to be accounted for"): a tagged ask leaves the hat once
// the person says anything after it (the transcript's card stays answerable, Leo 2026-11-05), or once
// a later turn ends; the chat's own question is declined when the person types a reply instead
// (App.tsx `withdrawForTypedReply`), and its transcript record then reads "Answered in chat"
// (direct.ts `recordQuestion`); one the agent or a Stop withdrew leaves when acpmux says so.
import { nextStepAsk, type NextStepAsk } from "../conversation/nextStepAsk";
import { NEXT_STEP } from "../conversation/turns";
import { askKey } from "../conversation/waitingAskStore";
import type { AcpmuxPermission, AcpmuxRow } from "../model";
import { pillAsks } from "../needsYou/jumpPillModel";
import { answersInPlace, needsYouItems, type NeedsYouItem, type WatchedAsk } from "../needsYou/model";
import { sessionIndex } from "../sessionIndex";
import { sessionTitle, type AcpmuxSessionEntry } from "../sessionList";
import { harnessName } from "../permissions/planBuild";
import type { Translate } from "../i18n";
import { hasPreviews, isPending, recommendedLabel, type AgentQuestion } from "./model";

/// The rulebook's tags for an ask only a person can answer, plus a check-in (a yes-or-no "still
/// want this?"). A question's header chip that names one counts as its tag.
export type HatTag = "taste" | "irreversible" | "outward" | "physical" | "check-in" | "for you";
const TAGS: readonly HatTag[] = ["taste", "irreversible", "outward", "physical", "check-in", "for you"];

export const hatTag = (text: string | undefined): HatTag | undefined => {
  const word = text
    ?.trim()
    .toLowerCase()
    .replace(/^\[|\]$/g, "")
    .replace(/^check\s+in$/, "check-in");
  return TAGS.find((tag) => tag === word);
};

/// One answer the hat draws as a button. `key` names the pane's own words for an answer the
/// next-step card made up (Yes, Not now).
export type HatAnswer = { id: string; label: string; key?: "recap.yes" | "recap.notNow"; recommended?: boolean };

export type HatQuestion = {
  /// Stable while it waits: the permission id, or `next:<row id>` for a tagged ask.
  id: string;
  /// `own`: this chat's question, answered here; `nextStep`: the tagged ask its turn ended on,
  /// answered as the person's reply; `child`: a started chat's, opened in that chat.
  source: "own" | "nextStep" | "child";
  sessionId?: string;
  /// A tagged ask's card key (waitingAskStore.ts `askKey`): the hat and the card share its answer.
  answerKey?: string;
  tag?: HatTag;
  prompt: string;
  /// The question's second line: a tagged ask's words after its question, or what else it asks.
  detail?: string;
  /// Who asks, for a started chat's question: the chat's own name, else its agent ("Claude"),
  /// never its long title.
  who?: string;
  /// What it is about: the question's header ("Cleanup"), for a started chat's question.
  about?: string;
  /// One click sends one of these. Empty when the question needs more than a click (several
  /// questions in one ask, a multi-select, previews, a form): the card under the hat takes it.
  answers: HatAnswer[];
  /// The person may type their own answer (Other, or any reply to a tagged ask).
  typed: boolean;
  /// The question the card under the hat shows (PermissionAsk): the card answers it, with its whole
  /// keyboard (arrows, number keys, Other, Skip), so the hat only points to it.
  onCard?: boolean;
  question?: AgentQuestion;
  permission?: AcpmuxPermission;
  ask?: NextStepAsk;
};

/// The hat answers a question in one click only when one click is the whole answer: one question,
/// one choice among at most four, nothing to preview and no field to fill.
const ONE_CLICK = 4;
export function oneClickAnswers(question: AgentQuestion): HatAnswer[] {
  if (question.items.length !== 1) return [];
  const item = question.items[0]!;
  if (item.multiSelect || item.options.length === 0 || item.options.length > ONE_CLICK || hasPreviews(item)) return [];
  return item.options.map((option) => {
    const { label, recommended } = recommendedLabel(option.label);
    return { id: option.id, label, ...(recommended ? { recommended } : {}) };
  });
}

function ownQuestion(permission: AcpmuxPermission | undefined, onCard = false): HatQuestion | undefined {
  const question = permission?.question;
  if (!permission || !question || !isPending(question)) return undefined;
  const first = question.items[0];
  if (!first) return undefined;
  const more = question.items.length - 1;
  // One behind the card that needs more than a click waits for the card, which reaches it in turn:
  // the hat has nowhere to point it before then.
  const answers = onCard ? [] : oneClickAnswers(question);
  if (!onCard && answers.length === 0) return undefined;
  return {
    id: permission.permissionId,
    source: "own",
    sessionId: question.source.session,
    ...(hatTag(first.header) ? { tag: hatTag(first.header) } : {}),
    prompt: first.prompt,
    ...(more > 0 ? { detail: question.items[1]!.prompt } : {}),
    answers: onCard ? [] : answers,
    typed: question.items.length === 1 && first.allowsOther,
    ...(onCard ? { onCard } : {}),
    question,
    permission,
  };
}

/// The person's own prompt (sent, or on its way): it moves a tagged ask past its relevance. The same
/// rule as the card's (turns.ts `personPrompt`): another agent's message, one received from elsewhere,
/// a blank one or one that failed to send answers nothing, so the ask stays.
const personSaid = (row: AcpmuxRow) =>
  row.kind === "user" && !row.incoming && !row.received && !row.failed && Boolean(row.text);

/// The tagged ask the chat's last turn ended on, while nothing the person said came after it. Read
/// from the end of the shaped rows and stopped at the first prompt of the person's or the first
/// card, so it costs the rows since the person's last prompt, never the chat's length.
export function liveNextStep(rows: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (personSaid(row)) return undefined;
    if (row.kind !== NEXT_STEP) continue;
    const step = row.nextStep;
    if (!step || step.answer !== undefined || step.superseded) return undefined;
    return step.ask.question && step.ask.options.length > 0 ? row : undefined;
  }
  return undefined;
}

/// The same in the Messages presentation, whose rows are the source's, unshaped: the reply of a turn
/// that completed, with nothing the person said after it, read as `turns.ts` reads it. Stopped at the
/// turn's start, so it also costs the rows since the person's last prompt.
export function messagesNextStep(rows: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  let completed = false;
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    // The person's prompt answers it; another one (an agent's message, a failed send) answers nothing.
    if (personSaid(row)) return undefined;
    if (row.kind === "user") continue;
    if (row.kind === "turnSummary") {
      if (completed || row.status !== "completed") return undefined;
      completed = true;
      continue;
    }
    if (row.kind !== "assistant" || !row.text?.trim()) continue;
    if (!completed) return undefined;
    const ask = nextStepAsk(row.text);
    return ask?.question && ask.options.length > 0
      ? { id: `${NEXT_STEP}-${row.id}`, version: row.version, at: row.at, kind: NEXT_STEP, nextStep: { ask } }
      : undefined;
  }
  return undefined;
}

function nextStepQuestion(row: AcpmuxRow | undefined, owner: string): HatQuestion | undefined {
  const ask = row?.nextStep?.ask;
  if (!row || !ask) return undefined;
  return {
    id: `next:${row.id}`,
    sessionId: owner,
    answerKey: askKey(row),
    source: "nextStep",
    ...(hatTag(ask.tag) ? { tag: hatTag(ask.tag) } : {}),
    prompt: ask.question,
    ...(ask.detail ? { detail: ask.detail } : {}),
    answers: ask.options.map((option) => ({
      id: option.label,
      label: option.label,
      ...(option.key ? { key: option.key } : {}),
    })),
    typed: true,
    ask,
  };
}

/// The questions of the chats `sessionId` started, at any depth (`pillAsks`), as the hat lists them:
/// a question each, never a tool's approval (that is the chat's own card) or another computer's.
function childQuestions(
  sessionId: string,
  sessions: readonly AcpmuxSessionEntry[],
  asks: readonly WatchedAsk[],
): HatQuestion[] {
  // Only the chats this one started: the list is built from their asks alone, so its cost follows
  // what this chat started, never every chat acpmux knows. Whether a chat was started is read from
  // the list's shared index (sessionIndex.ts) for the asking chats only, so one session's change
  // costs no pass over the list either. A list that names an id twice takes the pass.
  const index = sessionIndex(sessions);
  if (!index.has("started")) return [];
  let items: NeedsYouItem[];
  if (index.unique) {
    const started = (id: string) => {
      const session = index.get(id);
      return Boolean(session?.startedBy || session?.spawnedBy);
    };
    const theirs = asks.filter((ask) => started(ask.sessionId));
    const asking = needsYouItems({ sessions, asks: theirs }).filter((item) => started(item.sessionId));
    items = pillAsks(asking, sessions, sessionId);
  } else {
    const started = sessions.filter((session) => session.startedBy || session.spawnedBy);
    const ids = new Set(started.map((session) => session.sessionId));
    const theirs = asks.filter((ask) => ids.has(ask.sessionId));
    items = pillAsks(needsYouItems({ sessions: started, asks: theirs }), sessions, sessionId);
  }
  const out: HatQuestion[] = [];
  for (const item of items) {
    if (item.sessionId === sessionId || !item.sessionId) continue;
    if (item.kind !== "decision" && item.kind !== "verify") continue;
    const first = item.question?.items[0];
    const header = first?.header?.trim();
    const tag = hatTag(header);
    // A one-question ask with an id to answer is answered here: its choices as buttons, and a
    // typed answer when it takes one. Anything longer opens its chat, where its card takes it.
    const answerable = Boolean(
      item.question && item.permissionId && item.question.items.length === 1 && answersInPlace(item.question),
    );
    out.push({
      id: item.id,
      source: "child",
      sessionId: item.sessionId,
      ...(tag ? { tag } : {}),
      ...(header && !tag ? { about: header } : {}),
      prompt: first?.prompt ?? item.ask,
      who: askerName(index.get(item.sessionId), item.who.name),
      answers: answerable && item.question ? oneClickAnswers(item.question) : [],
      typed: answerable && Boolean(first?.allowsOther) && !first?.multiSelect && !(first && hasPreviews(first)),
      ...(item.question ? { question: item.question } : {}),
    });
  }
  // Oldest first: they join the hat's end as they come (needsYouItems lists newest first).
  return out.reverse();
}

/// Who asks a started chat's question, short: the chat's own name when it has one (`sessionTitle`
/// without its title and prompt), else its agent's name, else what Needs you calls it.
const NO_WORDS: Translate = () => "";
function askerName(session: AcpmuxSessionEntry | undefined, fallback: string): string {
  if (!session) return fallback;
  const named = sessionTitle({ ...session, title: "", lastPrompt: "" }, NO_WORDS);
  return named || (session.harness ? harnessName(session.harness) : fallback);
}

/// Whether the hat has anything to show: a question only the card's own is answered on the card,
/// with nothing to step to, so the band stays away rather than ask it twice.
export const hatShows = (questions: readonly HatQuestion[]): boolean => questions.some((question) => !question.onCard);

export type HatQuestionInput = {
  sessionId?: string;
  /// The question card the chat shows now (App.tsx `individualPermission`).
  permission?: AcpmuxPermission;
  /// The chat's other asks, behind that card (snapshot `permissionsQueued`).
  queued?: readonly AcpmuxPermission[];
  /// The shaped rows (App.tsx `turnRowsShown`), where a tagged ask's card is; in the Messages
  /// presentation (`messages`), the source rows, which the hat reads the ask from itself.
  rows: readonly AcpmuxRow[];
  messages?: boolean;
  /// The chat a tagged ask's answer would go to (App.tsx `restartOwner`); none, no tagged ask.
  nextStepOwner?: string;
  sessions: readonly AcpmuxSessionEntry[];
  asks: readonly WatchedAsk[];
};

export function hatQuestions(input: HatQuestionInput): HatQuestion[] {
  const out: HatQuestion[] = [];
  // The chat's own questions: the one its card shows, then every other one acpmux holds open for it
  // (subagents asking side by side), oldest first, so each can be stepped to and answered.
  const own = ownQuestion(input.permission, true);
  if (own) out.push(own);
  const seen = new Set(own ? [own.id] : []);
  for (const queued of input.queued ?? []) {
    const more = seen.has(queued.permissionId) ? undefined : ownQuestion(queued);
    if (more) out.push(more);
    seen.add(queued.permissionId);
  }
  if (input.sessionId)
    for (const watched of input.asks) {
      if (watched.sessionId !== input.sessionId || seen.has(watched.permission.permissionId)) continue;
      const more = ownQuestion(watched.permission);
      if (more) out.push(more);
      seen.add(watched.permission.permissionId);
    }
  // A tagged ask is the end of a finished turn: while the chat's own question waits, a turn runs.
  // Only where the composer would send it (App.tsx `restartOwner`): its answer is the person's reply.
  const owner = input.nextStepOwner;
  const next =
    out.length > 0 || !owner
      ? undefined
      : nextStepQuestion(input.messages ? messagesNextStep(input.rows) : liveNextStep(input.rows), owner);
  if (next) out.push(next);
  if (input.sessionId) out.push(...childQuestions(input.sessionId, input.sessions, input.asks));
  return out;
}

/// The question shown after the list changed: the same one while it waits, else the one that took
/// its place (the next, or the last when it was the end), else the first.
export function keepShown(
  questions: readonly HatQuestion[],
  shown: string | undefined,
  before: readonly string[],
): number {
  if (questions.length === 0) return 0;
  const now = questions.findIndex((question) => question.id === shown);
  if (now >= 0) return now;
  const was = shown === undefined ? -1 : before.indexOf(shown);
  if (was < 0) return 0;
  // The first of the questions after it that still waits, else the one before it.
  for (let at = was + 1; at < before.length; at += 1) {
    const index = questions.findIndex((question) => question.id === before[at]);
    if (index >= 0) return index;
  }
  return Math.min(was, questions.length - 1);
}

/// Whether two lists draw the same: the pane keeps the older list while this holds, so a streamed
/// chunk (which shapes the rows anew) never redraws the hat.
export function sameHatQuestions(a: readonly HatQuestion[], b: readonly HatQuestion[]): boolean {
  return (
    a.length === b.length &&
    a.every((question, index) => {
      const other = b[index]!;
      return (
        question.id === other.id &&
        question.prompt === other.prompt &&
        question.detail === other.detail &&
        question.tag === other.tag &&
        question.who === other.who &&
        question.about === other.about &&
        question.question?.id === other.question?.id &&
        question.typed === other.typed &&
        question.onCard === other.onCard &&
        question.permission === other.permission &&
        question.answers.length === other.answers.length &&
        question.answers.every(
          (answer, at) =>
            answer.id === other.answers[at]!.id &&
            answer.label === other.answers[at]!.label &&
            answer.recommended === other.answers[at]!.recommended,
        )
      );
    })
  );
}
