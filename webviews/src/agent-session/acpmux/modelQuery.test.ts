import { expect, test } from "bun:test";
import { effortWords, fitsQuery, parseQuery } from "./modelQuery";

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
