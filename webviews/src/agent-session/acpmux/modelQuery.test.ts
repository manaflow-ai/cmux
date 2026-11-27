import { expect, test } from "bun:test";
import * as modelQuery from "./modelQuery";
import { effortWords, fitsQuery, parseQuery } from "./modelQuery";

// The search both model menus run. Before it existed they filtered each model by the query alone,
// which is what the red commit runs.
const matchingModels: typeof modelQuery.matchingModels =
  modelQuery.matchingModels ?? ((models, query, fits) => models.filter((model) => fits(model, query)));

const efforts = effortWords([{ efforts: ["low", "medium", "high", "xhigh", "max"] }]);
const opus = { id: "claude-opus-5-5", name: "Opus 5.5", efforts: ["low", "medium", "high", "xhigh", "max"] };
const mini = { id: "gpt-5-mini", name: "GPT-5 mini", efforts: ["minimal", "low", "medium", "high"] };

// Lucas 2026-11-11: "allow for 'med' and 'medium'".
test("short and spelled-out effort forms name the effort", () => {
  expect(parseQuery("opus med", efforts)).toEqual({ words: ["opus"], effort: "medium" });
  expect(parseQuery("opus medium fast", efforts)).toEqual({ words: ["opus"], effort: "medium", fast: true });
  expect(parseQuery("opus hi", efforts).effort).toBe("high");
  expect(parseQuery("opus extra high", efforts)).toEqual({ words: ["opus"], effort: "xhigh" });
  expect(parseQuery("opus x-high", efforts).effort).toBe("xhigh");
});

test("a short form the catalog has no effort for stays a model word, and mini is never minimal", () => {
  const noMedium = effortWords([]);
  noMedium.delete("medium");
  expect(parseQuery("opus med", noMedium)).toEqual({ words: ["opus", "med"] });
  expect(parseQuery("gpt-5 mini", efforts).words).toEqual(["gpt-5", "mini"]);
});

test("a word matches with spaces, dots and dashes ignored", () => {
  for (const query of ["opus55", "opus 5.5", "claude-opus-5-5", "opus5.5 high", "OPUS 5-5"]) {
    expect(fitsQuery(opus, "Claude Code", parseQuery(query, efforts)), query).toBe(true);
  }
  expect(fitsQuery(mini, "Codex", parseQuery("gpt5 mini", efforts))).toBe(true);
  expect(fitsQuery(opus, "Claude Code", parseQuery("sonnet", efforts))).toBe(false);
});

// Lawrence 2026-11-19 (clip "CleanShot 2026-11-19 at 3.37.01 PM"): "why does the model disappear
// briefly". Typing "opus 5.5 medium" emptied the list to No matching models at "m", "me", "medi"
// and "mediu", and brought it back at "med" and "medium": a half-typed effort word was searched as a
// model word. The words being typed that can still become an effort or "fast" keep what the rest
// of the query found, unless they match a model as they are ("gpt 5 mi" still finds GPT-5 mini).
test("a half-typed effort or fast word keeps the models the rest of the query found", () => {
  const gpt5 = { id: "gpt-5", name: "GPT-5", efforts: ["minimal", "low", "medium", "high"] };
  const models = [opus, mini, gpt5];
  const harness = (model: { id: string }) => (model.id.startsWith("gpt") ? "Codex" : "Claude Code");
  const search = (query: string) =>
    matchingModels(models, parseQuery(query, efforts), (model, parsed) => fitsQuery(model, harness(model), parsed)).map(
      (model) => model.id,
    );
  for (const query of [
    "opus 5.5 m",
    "opus 5.5 me",
    "opus 5.5 medi",
    "opus 5.5 mediu",
    "opus 5.5 medium",
    "opus 5.5 med",
    "opus hig",
    "opus x",
    "opus extra",
    "opus extra h",
    "opus extra hig",
    "opus f",
    "opus fas",
    "opus medium fa",
  ])
    expect(search(query), query).toEqual(["claude-opus-5-5"]);
  expect(search("gpt 5 mi")).toEqual(["gpt-5-mini"]);
  expect(search("gpt 5 mini")).toEqual(["gpt-5-mini"]);
  // A finished word (a space after it) is searched as typed.
  expect(search("opus 5.5 m ")).toEqual([]);
  expect(search("sonnet")).toEqual([]);
});

test("the family-version shorthand resolves the requested Astra model, effort and speed", () => {
  const request = parseQuery("astra-6.2 fast high", efforts);
  const model = { id: "gpt-6.2-astra", name: "GPT-6.2 Astra", fast: true, efforts: ["high"] };
  expect(fitsQuery(model, "Codex", request)).toBe(true);
  expect(fitsQuery({ ...model, id: "gpt-6-astra", name: "Astra" }, "Codex", request)).toBe(false);
  expect(fitsQuery({ ...model, fast: false }, "Codex", request)).toBe(false);
});
