// The model picker's typed query (Lawrence 2026-10-08: "type like 'gpt medium fast' and it needs to
// update the other things too"). A query is words: a word that names a reasoning effort sets the
// effort (its short forms too: "med", "hi", "extra high"), "fast" turns fast mode on, and the rest
// match a model by its name, its id or its harness name, punctuation and spaces aside. Typing searches every harness at once; a pick lands the model with the effort and the fast
// mode the query named.

/// The efforts a word may name, in the order the agents list them. A catalog's own effort ids
/// join these (`effortWords`), so a harness with other names still matches.
const KNOWN_EFFORTS = ["minimal", "low", "medium", "high", "xhigh", "max"];
/// Words that turn fast mode on.
const FAST_WORDS = new Set(["fast", "fastmode"]);
/// Short and spelled-out forms of an effort (Lucas 2026-11-11: "allow for 'med' and 'medium'"). A form counts only
/// when the catalog has its effort. No prefix guessing: "mini" stays a model word (GPT-5 mini), never "minimal".
const EFFORT_ALIASES: Readonly<Record<string, string>> = {
  med: "medium",
  mid: "medium",
  lo: "low",
  hi: "high",
  xh: "xhigh",
  "x-high": "xhigh",
  extrahigh: "xhigh",
  "extra-high": "xhigh",
  maximum: "max",
};

/// A word or name with only its letters and digits ("Opus 5.5" and "claude-opus-5-5" read "opus55").
const compact = (text: string) => text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");

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
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  for (let index = 0; index < words.length; index += 1) {
    const word = words[index]!;
    // "extra high" is one effort in two words.
    const pair = word === "extra" && words[index + 1] === "high" ? "xhigh" : undefined;
    const effort = pair ?? (efforts.has(word) ? word : EFFORT_ALIASES[word]);
    if (FAST_WORDS.has(word)) parsed.fast = true;
    else if (effort && efforts.has(effort) && parsed.effort === undefined) {
      parsed.effort = effort;
      if (pair) index += 1;
    } else parsed.words.push(word);
  }
  return parsed;
}

export type QueryModel = { id: string; name: string; efforts?: string[]; fast?: boolean };

/// Whether `model` of `harnessName` fits the query: every word in its name, id or harness name;
/// the named effort among its efforts and fast mode among its options, when the catalog lists them.
export function fitsQuery(model: QueryModel, harnessName: string, query: ParsedQuery): boolean {
  const text = `${model.name} ${model.id} ${harnessName}`.toLowerCase();
  // A word matches as typed, or with spaces, dots and dashes ignored on both sides ("opus55", "gpt5.5", "4-5").
  const flat = `${compact(model.name)} ${compact(model.id)} ${compact(harnessName)}`;
  if (!query.words.every((word) => text.includes(word) || (compact(word) !== "" && flat.includes(compact(word)))))
    return false;
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
