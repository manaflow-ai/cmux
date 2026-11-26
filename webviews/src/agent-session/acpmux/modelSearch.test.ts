import { expect, test } from "bun:test";
import { effortWords, fitsQuery, matchingModels, narrows, parseQuery } from "./modelQuery";
import { ModelSearchIndex } from "./modelSearch";

type Model = { id: string; name: string; efforts?: string[]; fast?: boolean };
type Entry = { name: string; models: Model[] };

const entries: Entry[] = [
  {
    name: "Claude Code",
    models: [
      { id: "claude-opus-5-5", name: "Opus 5.5", efforts: ["low", "medium", "high"] },
      { id: "claude-sonnet-5", name: "Sonnet 5", efforts: ["low", "high"], fast: false },
      { id: "claude-haiku-4-5", name: "Haiku 4.5" },
    ],
  },
  {
    name: "Codex",
    models: [
      { id: "gpt-5-mini", name: "GPT-5 mini", efforts: ["minimal", "low", "medium", "high"] },
      { id: "gpt-5.5", name: "GPT-5.5", efforts: ["low", "medium", "high"], fast: true },
      ...Array.from({ length: 200 }, (_, index) => ({ id: `router/m-${index}`, name: `Model ${index} hi-fi` })),
    ],
  },
];
const efforts = effortWords(entries.flatMap((entry) => entry.models));
// The full pass the picker made before the index: matchingModels over every model, with its
// fallback for an effort word still being typed.
const full = (query: string) =>
  matchingModels(
    entries.flatMap((entry) => entry.models.map((model) => ({ model, entry }))),
    parseQuery(query, efforts),
    ({ model, entry }, parsed) => fitsQuery(model, entry.name, parsed),
  ).map(({ model }) => model.id);

test("the index finds what a full pass finds, in catalog order, however the query was reached", () => {
  const index = new ModelSearchIndex(
    entries,
    (entry) => entry.models,
    (entry) => entry.name,
  );
  // Typing on, deleting, an effort word ("h" then "hi" then "high"), fast mode, punctuation and
  // spaces ignored, a word that only its compact form matches, and back again.
  const steps = [
    "o",
    "op",
    "opu",
    "opus",
    "opus ",
    "opus 5",
    "opus 5.",
    "opus 5.5",
    "opus 5.",
    "opus",
    "o",
    "",
    "g",
    "gp",
    "gpt",
    "gpt5",
    "gpt5 h",
    "gpt5 hi",
    "gpt5 hig",
    "gpt5 high",
    "gpt5 high fast",
    "gpt5 high",
    "m",
    "mo",
    "model 1",
    "model 12",
    "model 1",
    "hi",
    "hi-",
    "hi-f",
    "hi-fi",
    "hifi",
    "-",
    "-f",
    "c",
    "co",
    "cod",
    "code",
    "codex",
    "codex m",
    "codex mi",
    "codex min",
    "codex mini",
    "codex mi",
  ];
  for (const query of steps) {
    const found = index.find(parseQuery(query, efforts)).map((row) => row.model.id);
    expect(found, JSON.stringify(query)).toEqual(full(query));
  }
});

test("a query narrows an earlier one only when every match of it is one of the earlier's", () => {
  const q = (text: string) => parseQuery(text, efforts);
  expect(narrows(q("op"), q("opu"))).toBe(true);
  expect(narrows(q("opus"), q("opus 5"))).toBe(true);
  expect(narrows(q("gpt5"), q("gpt5 high"))).toBe(true);
  expect(narrows(q("gpt5 high"), q("gpt5 high fast"))).toBe(true);
  expect(narrows(q("opus 5"), q("opus"))).toBe(false);
  expect(narrows(q("opu"), q("op"))).toBe(false);
  // "hi" is an effort, not a word: the word "h" is gone.
  expect(narrows(q("gpt5 h"), q("gpt5 hi"))).toBe(false);
  expect(narrows(q("gpt5 high"), q("gpt5"))).toBe(false);
  // A word with no letters or digits matches as typed only.
  expect(narrows(q("-"), q("-f"))).toBe(false);
});

test("an effort word still being typed keeps the models the rest of the query finds", () => {
  const index = new ModelSearchIndex(
    entries,
    (entry) => entry.models,
    (entry) => entry.name,
  );
  const ids = (query: string) => index.find(parseQuery(query, efforts)).map((row) => row.model.id);
  // "m" on the way to "medium": Opus stays listed while it is typed, as the full picker kept it.
  expect(ids("opus 5.5 m")).toEqual(["claude-opus-5-5"]);
  expect(ids("opus 5.5 med")).toEqual(["claude-opus-5-5"]);
  expect(ids("opus 5.5 medium")).toEqual(["claude-opus-5-5"]);
});
