/// What Return does with the New Tab field's text (Leo 2026-10-20: "no mode toggle: type and press
/// Return"). An address opens; a question or an instruction for an agent asks it; anything else is a
/// web search. Pure and synchronous: the page decides on every keystroke, and the decision is the
/// suggestions' first row, so an arrow picks another row for the rare miss.
import { classifyNewTabInput, type NewTabIntentOptions } from "./newTabIntent";

export type OmniboxAction =
  | { kind: "none" }
  /// `!` first: the tab becomes a terminal (newTabIntent).
  | { kind: "terminal"; command: string }
  | { kind: "open"; url: string }
  | { kind: "ask"; text: string }
  | { kind: "search"; text: string };

/// Words that start a question or an instruction to an agent, with at least one more word after
/// them: "fix" alone is a search, "fix the login test" a request.
const LEADS = new Set([
  "what",
  "what's",
  "whats",
  "how",
  "how's",
  "why",
  "when",
  "where",
  "who",
  "whom",
  "whose",
  "which",
  "isn't",
  "aren't",
  "doesn't",
  "don't",
  "didn't",
  "can't",
  "won't",
  "wouldn't",
  "shouldn't",
  "couldn't",
  "analyze",
  "analyse",
  "compare",
  "convert",
  "create",
  "debug",
  "describe",
  "explain",
  "fix",
  "generate",
  "implement",
  "investigate",
  "refactor",
  "rewrite",
  "summarize",
  "summarise",
  "tell",
  "translate",
  "write",
  "please",
  "let's",
  "lets",
]);

/// Lead words that are as often a search's first noun or name ("can opener", "find my iphone",
/// "my little pony"): a request only with at least three more words.
const WEAK_LEADS = new Set([
  "can",
  "could",
  "should",
  "would",
  "is",
  "are",
  "am",
  "was",
  "were",
  "do",
  "does",
  "did",
  "will",
  "shall",
  "may",
  "might",
  "must",
  "has",
  "have",
  "had",
  "add",
  "build",
  "change",
  "check",
  "clean",
  "delete",
  "design",
  "draft",
  "edit",
  "find",
  "help",
  "improve",
  "list",
  "make",
  "migrate",
  "move",
  "optimize",
  "optimise",
  "plan",
  "remove",
  "rename",
  "review",
  "run",
  "set",
  "show",
  "tail",
  "test",
  "update",
  "upgrade",
  "i",
  "i'm",
  "i've",
  "we",
  "you",
  "my",
  "our",
  "this",
  "it",
  "it's",
]);

/// A verb's object right after it: "open the settings", "sketch a name", "give me ideas".
const OBJECTS = new Set([
  "a",
  "an",
  "the",
  "me",
  "us",
  "it",
  "my",
  "our",
  "your",
  "this",
  "that",
  "these",
  "those",
  "some",
  "all",
]);

/// First words that are not a verb, so "the" or "a" second is a title, not an object: "under the
/// tuscan sun", "around the world in 80 days".
const NOT_VERBS = new Set([
  "a",
  "an",
  "the",
  "about",
  "above",
  "across",
  "after",
  "against",
  "along",
  "among",
  "around",
  "at",
  "before",
  "behind",
  "below",
  "beneath",
  "beside",
  "between",
  "beyond",
  "by",
  "down",
  "for",
  "from",
  "in",
  "inside",
  "into",
  "near",
  "of",
  "off",
  "on",
  "out",
  "outside",
  "over",
  "past",
  "since",
  "through",
  "to",
  "toward",
  "towards",
  "under",
  "until",
  "up",
  "upon",
  "with",
  "within",
  "without",
]);

/// Pointing words after a request word: "make this faster", "move it up". Only after a lead the
/// lists know, so a title with any other verb stays a search ("shake it off", "let it be").
const POINTERS = new Set(["this", "that", "it", "these", "those"]);

/// A sentence this long is a request, not search keywords.
const LONG_SENTENCE_WORDS = 10;
/// Fewer words than this with a comma or a semicolon are still keywords ("rust, go").
const CLAUSE_WORDS = 6;

export function omniboxAction(input: string, options: NewTabIntentOptions = {}): OmniboxAction {
  const intent = classifyNewTabInput(input, options);
  switch (intent.kind) {
    case "none":
    case "terminal":
      return intent;
    case "url":
      return { kind: "open", url: intent.url };
    case "prompt":
      return readsAsRequest(intent.text) ? { kind: "ask", text: intent.text } : { kind: "search", text: intent.text };
    // A pairing link (its room secret) is never asked, searched or opened.
    case "refused":
      return { kind: "none" };
  }
}

/// A question mark, a leading question or instruction word, a verb and its object, more than one
/// line or sentence, a clause break in a sentence, inline code, or a long sentence.
export function readsAsRequest(text: string): boolean {
  if (text.includes("?") || text.includes("`") || /[\n\r]/.test(text)) return true;
  const words = text.split(/\s+/).filter(Boolean);
  const [lead, second] = words.slice(0, 2).map((word) =>
    word
      .toLowerCase()
      .replace(/[’]/g, "'")
      .replace(/[^\p{L}']/gu, ""),
  );
  if (lead && LEADS.has(lead) && words.length >= 2) return true;
  if (lead && WEAK_LEADS.has(lead) && words.length >= 4) return true;
  // An imperative: a verb, then its object ("open the voice settings").
  if (lead && second && OBJECTS.has(second) && !NOT_VERBS.has(lead) && words.length >= 4) return true;
  // A known request word and "the": "run the tests", "tail the logs" ("build a bear" stays a title).
  if (lead && second === "the" && WEAK_LEADS.has(lead) && words.length >= 3) return true;
  if (lead && second && POINTERS.has(second) && WEAK_LEADS.has(lead) && !OBJECTS.has(lead) && words.length >= 3)
    return true;
  // "It broke. Fix it": a word's sentence end, then a new sentence ("St. Louis" stays a name).
  if (/\p{L}{3,}[.!]\s+\p{Lu}/u.test(text)) return true;
  if (words.length >= CLAUSE_WORDS && /[,;:]\s/.test(text)) return true;
  return words.length >= LONG_SENTENCE_WORDS;
}
