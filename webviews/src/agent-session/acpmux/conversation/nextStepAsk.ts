// A question an agent asks in its own words at the end of a turn, tagged the way Leo's sessions tag
// the asks only a person can answer (`[taste]`, `[outward]`, `[irreversible]`, `[physical]`,
// `[for you]`), read out of the turn's final answer so the transcript can draw it as a card with
// its answers as buttons (NextStepCard.tsx). Leo, 2026-11-03, on Claude desktop's next-step box:
// "sometimes i guess there's a bunch of ad-hoc [outward] or [for you] type things that the
// coordinator or other sessions do and i feel like for multiple choice things like that we can just
// render something pretty and usable". He also worried it "might be more tiresome than otherwise",
// so the reading is strict: a card only where the agent really asked one tagged question with
// answers to click, and never for ordinary prose.

import { quoteMarkdown } from "./selectionReplyModel";

/// One answer button: what it sends as the person's reply, and the pane's own words for it when the
/// card made the answer up (Yes and Not now for a yes-or-no question), which it draws instead.
export type NextStepOption = { label: string; key?: "recap.yes" | "recap.notNow" };

/// How to try what a finished wrap-up made (acpmux `wrap_up`'s `try`, `verify` and `report`): a
/// Try button that opens `url` in a browser tab or runs `command` in a new terminal, the steps to
/// check once it runs, and the HTML report. Aziz, 2026-11-09: "theres a direct way for me to try
/// out and verify its work in addition to the artifact."
export type WrapUpTry = {
  /// The button's words; absent when the wrap-up gave only steps or a report.
  label?: string;
  url?: string;
  command?: string;
  verify: string[];
  report?: string;
};

export type NextStepAsk = {
  /// The tag the line carried, lowercased ("outward"), or `wrap_up` for the agent's own wrap-up
  /// call (wrapUp.ts).
  tag: string;
  /// What changed and where things stand, two or three sentences, muted above the question: only a
  /// wrap-up call carries one.
  recap?: string;
  /// The question, through its last question mark, without the tag or a "For Leo:" lead. Empty
  /// for a wrap-up with nothing to decide, which draws the recap alone.
  question: string;
  /// What the line said after the question ("My pick: yes."), muted under it; absent when nothing.
  detail?: string;
  /// Two to four answers; the first is the primary (⌘↩). A wrap-up's may hold one, or none with
  /// no question.
  options: NextStepOption[];
  /// A finished wrap-up's Try button, Verify steps and report (wrapUp.ts).
  tryIt?: WrapUpTry;
  /// The answer's text without the ask's lines (the tagged line and its option list), which the
  /// card draws instead. Blank lines the removal leaves at the end are trimmed.
  rest: string;
};

const TAGS = ["taste", "outward", "irreversible", "physical", "check-in", "for you"];
// A line that starts with the tag, after an optional list marker or bold: `- **[outward]** ...`.
const TAGGED = new RegExp(
  String.raw`^\s{0,3}(?:[-*+]\s+|\d{1,2}[.)]\s+)?(?:\*\*|__)?\[(${TAGS.join("|")})\](?:\*\*|__)?:?\s+(.+?)\s*$`,
  "i",
);
// "For Leo:", "For you:", "Leo:" before the question.
const LEAD = /^(?:(?:\*\*)?for\s+(?:leo|you)(?:\*\*)?\s*:\s*|leo\s*:\s*)/i;
const LIST_ITEM = /^\s{0,3}(?:[-*+]|\d{1,2}[.)])\s+(.+?)\s*$/;
const FENCE = /^\s{0,3}(```|~~~)/;
// A yes-or-no question opens with an auxiliary or modal verb ("Should I remove ...?").
const YES_NO =
  /^(?:should|shall|may|can|could|do|does|did|is|are|was|were|will|would|want|ok|okay|go ahead|proceed|merge|land|approve)\b/i;

/// The longest answer a button takes; a longer list item is prose, not an answer.
const MAX_LABEL = 80;
const MAX_OPTIONS = 4;

const plainLabel = (text: string) =>
  text
    .replace(/^(?:\*\*|__)(.+)(?:\*\*|__)$/, "$1")
    .replace(/^`(.+)`$/, "$1")
    .trim();

/// The tagged ask at the end of `text`, or undefined when there is none or it is not clear enough
/// to draw: exactly one tagged line that asks a question (a question mark outside code), not in a
/// code block or a quote, followed by a list of two to four short answers, or with no list when it
/// is a yes-or-no question (then Yes and Not now). Several tagged questions in one answer draw none: the
/// buttons could not say which one they answer.
export function nextStepAsk(text: string | undefined): NextStepAsk | undefined {
  if (!text || !text.includes("[")) return undefined;
  const lines = text.split("\n");
  let fenced = false;
  const found: { at: number; tag: string; body: string }[] = [];
  for (let at = 0; at < lines.length; at += 1) {
    const line = lines[at]!;
    if (FENCE.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced || /^\s{0,3}>/.test(line)) continue;
    const match = TAGGED.exec(line);
    if (!match) continue;
    const body = match[2]!.replace(/`[^`]*`/g, (code) => code.replace(/\?/g, "\u0000"));
    if (!body.includes("?")) continue;
    found.push({ at, tag: match[1]!.toLowerCase(), body: match[2]! });
  }
  if (found.length !== 1) return undefined;
  const { at, tag, body } = found[0]!;
  const lead = body.replace(LEAD, "");
  // The question runs through its last question mark outside inline code.
  let end = -1;
  let inCode = false;
  for (let index = 0; index < lead.length; index += 1) {
    if (lead[index] === "`") inCode = !inCode;
    else if (lead[index] === "?" && !inCode) end = index;
  }
  if (end < 0) return undefined;
  const asked = lead.slice(0, end + 1).trim();
  // "For Leo: which ...?" reads as a sentence once its lead goes.
  const question = asked.charAt(0).toUpperCase() + asked.slice(1);
  const detail = lead.slice(end + 1).trim() || undefined;
  // The answers: a list right under the line, a blank line between allowed.
  let next = at + 1;
  if (next < lines.length && lines[next]!.trim() === "" && LIST_ITEM.test(lines[next + 1] ?? "")) next += 1;
  const items: string[] = [];
  let stop = next;
  while (stop < lines.length) {
    const item = LIST_ITEM.exec(lines[stop]!);
    if (!item) break;
    items.push(plainLabel(item[1]!));
    stop += 1;
  }
  let options: NextStepOption[];
  let last = at;
  if (items.length) {
    if (items.length < 2 || items.length > MAX_OPTIONS || items.some((item) => !item || item.length > MAX_LABEL))
      return undefined;
    options = items.map((label) => ({ label }));
    last = stop - 1;
  } else if (YES_NO.test(asked)) {
    // Claude desktop's pair (Leo's reference): Yes, and Not now. The reply goes to the agent in
    // English; the buttons draw the pane's words (recap.yes, recap.notNow).
    options = [
      { label: "Yes", key: "recap.yes" }, // l10n-allow: a prompt to the agent, not UI
      { label: "Not now", key: "recap.notNow" }, // l10n-allow: a prompt to the agent, not UI
    ];
  } else return undefined;
  // One blank line stays where the ask's lines were between two paragraphs.
  const after = lines.slice(last + 1);
  if (at > 0 && lines[at - 1]!.trim() === "" && after[0]?.trim() === "") after.shift();
  const rest = [...lines.slice(0, at), ...after].join("\n").replace(/\s+$/, "");
  return { tag, question, ...(detail && { detail }), options, rest };
}

/// The option a prompt picked (case and outer space aside, and its quote of the ask, `answerOf`):
/// what a click on the card sends, or the same words typed. Undefined for any other prompt, which leaves the card answerable.
export function pickedAnswer(ask: NextStepAsk, reply: string): string | undefined {
  const said = answerOf(ask.question, reply).trim().toLowerCase();
  return ask.options.find((option) => option.label.toLowerCase() === said)?.label;
}

/// The answer the person gave: the option their prompt chose, else that prompt's first line, so a
/// typed answer reads too.
export function chosenAnswer(ask: NextStepAsk, reply: string): string {
  const picked = pickedAnswer(ask, reply);
  if (picked) return picked;
  const first = answerOf(ask.question, reply).trim().split("\n")[0]!.trim();
  return first.length > 120 ? `${first.slice(0, 119)}…` : first;
}

/// What a reply to an ask quotes: who asked and the question, as one line ("Claude Code: Should I
/// open a PR?"). Leo, 2026-11-08, on a bare "Not now" bubble: "wait this thing should've shown that
/// it was a reply to an ask from you". `asker` is the chat's agent; without one the question alone.
export function askQuote(question: string, asker?: string): string {
  const who = asker?.trim();
  return who ? `${who}: ${question}` : question;
}

/// The prompt an answer to an ask sends: the ask quoted as Quote in Reply quotes a selection
/// (selectionReplyModel.ts `quoteMarkdown`: `> ` lines, then a blank line), then the answer. The
/// bubble draws it as every quoted reply draws (a muted bar over the reply), the agent reads which
/// ask it answers, and every surface that shows the prompt shows the quote with it.
export function answerPrompt(question: string, answer: string, asker?: string): string {
  return question.trim() ? `${quoteMarkdown(askQuote(question, asker))}${answer}` : answer;
}

/// A prompt's reply without its quote of `question` (`answerPrompt`): the words the person gave,
/// whoever the quote names as asking. A prompt that quotes nothing, or something else, is itself.
export function answerOf(question: string, reply: string): string {
  if (!question || !/^\s{0,3}>/.test(reply)) return reply;
  const lines = reply.split("\n");
  let end = 0;
  while (end < lines.length && /^\s{0,3}>/.test(lines[end]!)) end += 1;
  const quoted = lines
    .slice(0, end)
    .map((line) => line.replace(/^\s{0,3}> ?/, ""))
    .join("\n")
    .trim();
  const asked = question.trim();
  if (quoted !== asked && !quoted.endsWith(`: ${asked}`)) return reply;
  return lines.slice(end).join("\n").trim();
}
