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
  /// The words at the end still being typed that can become an effort or "fast" ("m", "me" and
  /// "medi" of "medium", "extra hig"). They are also in `words`; ``matchingModels`` drops them
  /// when, as typed, they match no model.
  typing?: string[];
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
  const typing = typingWords(query, words, efforts);
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
  // Only words the query kept as model words, after at least one other: a query of a half-typed
  // word alone searches as typed.
  if (
    typing.length > 0 &&
    parsed.words.length > typing.length &&
    parsed.words.slice(-typing.length).join(" ") === typing.join(" ")
  )
    parsed.typing = typing;
  return parsed;
}

/// The words a still-open query ends with (no space after them) that are the start of an effort
/// or fast word the catalog knows: the last word, or "extra" and the start of "high".
function typingWords(query: string, words: readonly string[], efforts: ReadonlySet<string>): string[] {
  if (/\s$/.test(query) || words.length === 0) return [];
  const last = words.at(-1)!;
  const forms = [
    ...FAST_WORDS,
    ...efforts,
    ...Object.entries(EFFORT_ALIASES)
      .filter(([, effort]) => efforts.has(effort))
      .map(([alias]) => alias),
  ];
  if (words.at(-2) === "extra" && efforts.has("xhigh") && "high".startsWith(last)) return ["extra", last];
  return forms.some((form) => form !== last && form.startsWith(last)) ? [last] : [];
}

/// The models a query finds: those that fit it. When none fits and the query ends with an effort
/// or fast word still being typed, those words wait: the models the rest of the query finds stay
/// listed, so the list does not empty out and come back while "medium" is typed.
///
/// - Parameter fits: whether one model fits a query (``fitsQuery`` with the model's harness name).
export function matchingModels<Model>(
  models: readonly Model[],
  query: ParsedQuery,
  fits: (model: Model, query: ParsedQuery) => boolean,
): Model[] {
  const found = models.filter((model) => fits(model, query));
  if (found.length > 0 || !query.typing) return found;
  const words = query.words.slice(0, query.words.length - query.typing.length);
  const { typing: _typing, ...rest } = query;
  return models.filter((model) => fits(model, { ...rest, words }));
}

export type QueryModel = { id: string; name: string; efforts?: string[]; fast?: boolean };

/// What a query matches a model against: its name, id and harness name, lowercased (`text`) and
/// with only their letters and digits (`flat`). A search index (modelSearch.ts) makes these once per
/// catalog, so a typed key reads them rather than making them again for every model.
export type SearchKeys = { text: string; flat: string };

export function searchKeys(model: QueryModel, harnessName: string): SearchKeys {
  return {
    text: `${model.name} ${model.id} ${harnessName}`.toLowerCase(),
    flat: `${compact(model.name)} ${compact(model.id)} ${compact(harnessName)}`,
  };
}

/// A query's words compacted, once per query rather than once per model.
export function queryFlatWords(query: ParsedQuery): string[] {
  return query.words.map(compact);
}

/// `fitsQuery` on a model's `keys`, with the query's `flatWords` (queryFlatWords).
export function fitsKeys(
  keys: SearchKeys,
  model: QueryModel,
  query: ParsedQuery,
  flatWords: readonly string[],
): boolean {
  // A word matches as typed, or with spaces, dots and dashes ignored on both sides ("opus55", "gpt5.5", "4-5").
  for (let index = 0; index < query.words.length; index += 1) {
    const flatWord = flatWords[index]!;
    if (!keys.text.includes(query.words[index]!) && (flatWord === "" || !keys.flat.includes(flatWord))) return false;
  }
  if (query.effort && model.efforts && !model.efforts.some((effort) => effort.toLowerCase() === query.effort))
    return false;
  if (query.fast && model.fast === false) return false;
  return true;
}

/// Whether `model` of `harnessName` fits the query: every word in its name, id or harness name;
/// the named effort among its efforts and fast mode among its options, when the catalog lists them.
export function fitsQuery(model: QueryModel, harnessName: string, query: ParsedQuery): boolean {
  return fitsKeys(searchKeys(model, harnessName), model, query, queryFlatWords(query));
}

/// Whether every model `next` fits also fits `previous`, so `next`'s matches are among
/// `previous`'s: each earlier word is inside the word typed at its place (its letters and digits
/// too, never none), and the earlier effort and fast mode still hold. Typing on narrows; a deleted
/// letter or a word that became an effort ("hi") does not.
export function narrows(previous: ParsedQuery, next: ParsedQuery): boolean {
  if (next.words.length < previous.words.length) return false;
  if (previous.effort !== undefined && previous.effort !== next.effort) return false;
  if (previous.fast && !next.fast) return false;
  return previous.words.every((word, index) => {
    const typed = next.words[index]!;
    const flat = compact(word);
    return typed.includes(word) && flat !== "" && compact(typed).includes(flat);
  });
}

/// The effort id as the model lists it (its case), for the pick.
export function modelEffort(model: QueryModel, effort: string | undefined): string | undefined {
  if (!effort) return undefined;
  return model.efforts?.find((value) => value.toLowerCase() === effort) ?? effort;
}
