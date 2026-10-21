// The recap card's reading of a finished turn (RecapCard.tsx; Claude desktop's end-of-turn card):
// a turn that ended by asking the person something, such as "Should I open a PR for this?", gets
// a card with the answer one click away. No harness says that a turn asked; the card reads the
// turn's final answer, so it works for Claude, Codex and any ACP agent alike.
import type { AcpmuxRow } from "./model";

/** A finished turn that ends on a question. */
export type Recap = {
  /** The turn's summary row id: a dismissal keeps to this turn. */
  key: string;
  /** The answer's last paragraph before the question, as plain text (may be empty). */
  summary: string;
  /** The answer's closing sentence, which ends in "?". */
  question: string;
  /** What a yes agrees to, "open PR" for "Should I open a PR for this?"; unset for a plain yes. */
  action?: string;
  /** The prompt the yes sends: "Yes, open PR", or "Yes". */
  reply: string;
};

export type RecapState = {
  /** A turn runs: nothing has ended yet. */
  working?: boolean;
  /** A permission, question or secret waits for the person: that ask comes first. */
  asking?: boolean;
};

const ASK = /^(?:(?:so|ok|okay),?\s+)?(?:should i|shall i|do you want me to|want me to|would you like me to)\s+(.+)$/i;
const TRAILING = /\s+(?:for (?:this|you)|now|here|too)$/i;
const ARTICLES = new Set(["a", "an", "the"]);
const MAX_ACTION_WORDS = 4;

/// Markdown as the plain text it reads as: code fences gone, list and heading markers, emphasis
/// and inline code marks dropped, links and images as their text.
export function plainText(markdown: string): string {
  let fence: string | undefined;
  return markdown
    .split("\n")
    .filter((line) => {
      const mark = /^\s*(`{3,}|~{3,})/.exec(line)?.[1];
      if (fence) {
        if (mark?.startsWith(fence)) fence = undefined;
        return false;
      }
      if (mark) fence = mark;
      return !mark;
    })
    .map((line) =>
      line
        .replace(/^\s{0,3}#{1,6}\s+/, "")
        .replace(/^\s*(?:>\s?)+/, "")
        .replace(/^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/, "")
        .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
        .replace(/`([^`]*)`/g, "$1")
        .replace(/(\*\*|__|~~)(.+?)\1/g, "$2")
        .replace(/(^|[^\w*])\*(?!\s)([^*]+?)\*(?!\w)/g, "$1$2")
        .replace(/(^|[^\w])_(?!\s)([^_]+?)_(?!\w)/g, "$1$2")
        .trim(),
    )
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/// What a yes to `question` agrees to: "Should I open a PR for this?" agrees to "open PR". Unset
/// when the question offers no single short action (a choice, a long phrase, any other question).
export function recapAction(question: string): string | undefined {
  const body = question.replace(/[?？]+$/, "").trim();
  const match = ASK.exec(body);
  if (!match) return undefined;
  let phrase = match[1].replace(/[\s,;:.]+$/, "");
  if (/\bor\b/i.test(phrase)) return undefined;
  for (let before = ""; before !== phrase;) {
    before = phrase;
    phrase = phrase.replace(TRAILING, "");
  }
  const words = phrase.split(/\s+/).filter((word) => word && !ARTICLES.has(word.toLowerCase()));
  if (words.length === 0 || words.length > MAX_ACTION_WORDS) return undefined;
  // "Run" reads "run" after "Yes, "; an acronym such as "PR" keeps its case.
  if (/^[A-Z][a-z]/.test(words[0])) words[0] = words[0][0].toLowerCase() + words[0].slice(1);
  return words.join(" ");
}

/// The last turn's recap: set only when that turn completed (not failed or cancelled), nothing
/// runs or waits for the person, and its final answer's last sentence asks something.
export function recapFrom(rows: readonly AcpmuxRow[], state: RecapState = {}): Recap | null {
  if (state.working || state.asking) return null;
  let end = rows.length - 1;
  while (end >= 0 && rows[end].kind !== "turnSummary") {
    // A prompt after the last summary is a turn that has not ended.
    if (rows[end].kind === "user" || rows[end].streaming) return null;
    end -= 1;
  }
  if (end < 0) return null;
  const summaryRow = rows[end];
  if ((summaryRow.status ?? "completed") !== "completed" || summaryRow.error) return null;
  let answer: AcpmuxRow | undefined;
  for (let index = end - 1; index >= 0 && rows[index].kind !== "user"; index -= 1) {
    const row = rows[index];
    if (row.kind === "permission" && row.permission?.pending) return null;
    if (!answer && row.kind === "assistant") answer = row;
  }
  if (!answer || answer.streaming || !answer.text) return null;
  const text = plainText(answer.text);
  if (!/[?？]$/.test(text)) return null;
  const paragraphs = text.split(/\n\s*\n/);
  const last = paragraphs[paragraphs.length - 1];
  const lines = last.split("\n");
  const line = lines[lines.length - 1];
  // The closing sentence: after the last sentence end on the line (". ", "! ", "? ").
  const sentences = line.split(/(?<=[.!?。！？])\s+/);
  const question = sentences[sentences.length - 1].trim();
  if (!question) return null;
  const before = text.slice(0, text.length - question.length).trim();
  const summaryParagraphs = before.split(/\n\s*\n/);
  const summary = summaryParagraphs[summaryParagraphs.length - 1].replace(/\s*\n\s*/g, " ").trim();
  const action = recapAction(question);
  return {
    key: summaryRow.id,
    summary,
    question,
    ...(action ? { action } : {}),
    // The reply goes to the agent, in the words of its own question. l10n-allow: a prompt, not UI
    reply: action ? `Yes, ${action}` : "Yes",
  };
}
