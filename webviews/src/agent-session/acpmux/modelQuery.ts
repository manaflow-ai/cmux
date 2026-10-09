// The model picker's typed query (Lawrence 2026-10-08: "type like 'gpt medium fast' and it needs to
// update the other things too"). A query is words: a word that names a reasoning effort sets the
// effort, "fast" turns fast mode on, and the rest match a model by its name, its id or its harness
// name. Typing searches every harness at once; a pick lands the model with the effort and the fast
// mode the query named.

/// The efforts a word may name, in the order the agents list them. A catalog's own effort ids
/// join these (`effortWords`), so a harness with other names still matches.
const KNOWN_EFFORTS = ["minimal", "low", "medium", "high", "xhigh", "max"];
/// Words that turn fast mode on.
const FAST_WORDS = new Set(["fast"]);

export type ParsedQuery = {
  /// The words a model must match (name, id or harness name), lowercased.
  words: string[];
  /// The effort the query named, lowercased.
  effort?: string;
  /// The query turned fast mode on.
  fast?: true;
};

/// Every effort word the catalog knows, plus the common ones.
export function effortWords(models: Iterable<{ efforts?: string[] }>): Set<string> {
  const words = new Set(KNOWN_EFFORTS);
  for (const model of models) for (const effort of model.efforts ?? []) words.add(effort.toLowerCase());
  return words;
}

export function parseQuery(query: string, efforts: ReadonlySet<string>): ParsedQuery {
  const parsed: ParsedQuery = { words: [] };
  for (const word of query.trim().toLowerCase().split(/\s+/).filter(Boolean)) {
    if (FAST_WORDS.has(word)) parsed.fast = true;
    else if (efforts.has(word) && parsed.effort === undefined) parsed.effort = word;
    else parsed.words.push(word);
  }
  return parsed;
}

export type QueryModel = { id: string; name: string; efforts?: string[]; fast?: boolean };

/// Whether `model` of `harnessName` fits the query: every word in its name, id or harness name;
/// the named effort among its efforts and fast mode among its options, when the catalog lists them.
export function fitsQuery(model: QueryModel, harnessName: string, query: ParsedQuery): boolean {
  const text = `${model.name} ${model.id} ${harnessName}`.toLowerCase();
  if (!query.words.every((word) => text.includes(word))) return false;
  if (query.effort && model.efforts && !model.efforts.some((effort) => effort.toLowerCase() === query.effort))
    return false;
  if (query.fast && model.fast === false) return false;
  return true;
}

/// The effort id as the model lists it (its case), for the pick.
export function modelEffort(model: QueryModel, effort: string | undefined): string | undefined {
  if (!effort) return undefined;
  return model.efforts?.find((value) => value.toLowerCase() === effort) ?? effort;
}

/// How well `model` matches the query's words, lower is better: 0 the whole name, 1 a prefix of it,
/// 2 a word inside it starts the phrase, 3 the name contains every word, 4 only its id or harness
/// matched. Searching sorts by it (stably), so a typed "sonnet 5.5" lands on Sonnet 5.5 itself.
export function matchRank(model: QueryModel, _harnessName: string, query: ParsedQuery): number {
  const phrase = query.words.join(" ");
  if (!phrase) return 0;
  const name = model.name.toLowerCase();
  if (name === phrase) return 0;
  if (name.startsWith(phrase)) return 1;
  if (new RegExp(`(^|[\\s\\-_/().])${escapeRegExp(phrase)}`).test(name)) return 2;
  if (query.words.every((word) => name.includes(word))) return 3;
  return 4;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/// A context window as a compact count in the viewer's language ("200K", "1M").
export function compactContext(tokens: number | undefined, language: string): string | undefined {
  if (!tokens || tokens <= 0) return undefined;
  return new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 }).format(tokens);
}
