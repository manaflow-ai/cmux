// l10n-allow-file: test fixtures.
// A pull request another agent's message names twice in a row, written two ways, shows once
// (messageRefs.ts).
import { expect, test } from "bun:test";
import { dedupeReferences } from "./messageRefs";

test("a pull request written twice in a row shows once", () => {
  const repo = "manaflow-ai/cmux";
  expect(dedupeReferences("MERGED #23825 (4c656ea8) manaflow-ai/cmux#23825 — before: x", repo)).toBe(
    "MERGED #23825 (4c656ea8) — before: x",
  );
  expect(dedupeReferences("manaflow-ai/cmux#23825 (#23825) landed", repo)).toBe("manaflow-ai/cmux#23825 landed");
  expect(dedupeReferences("#1 (manaflow-ai/cmux#1, abc1234)", repo)).toBe("#1 (abc1234)");
  expect(dedupeReferences("hq#2563 / manaflow-ai/cmuxterm-hq#2563", repo)).toBe("hq#2563");
  // A later mention in its own words stays; so do different numbers and different repositories.
  expect(dedupeReferences("Merged #5. Next, #5 needs a rebase.", repo)).toBe("Merged #5. Next, #5 needs a rebase.");
  expect(dedupeReferences("#5 #6", repo)).toBe("#5 #6");
  expect(dedupeReferences("#5 hq#5", repo)).toBe("#5 hq#5");
  // Without a repository a bare number names nothing, so nothing is a repeat.
  expect(dedupeReferences("#5 manaflow-ai/cmux#5", undefined)).toBe("#5 manaflow-ai/cmux#5");
  // Code and links are not prose.
  expect(dedupeReferences("`#5 manaflow-ai/cmux#5`", repo)).toBe("`#5 manaflow-ai/cmux#5`");
  expect(dedupeReferences("#5 [manaflow-ai/cmux#5](https://x.test)", repo)).toBe(
    "#5 [manaflow-ai/cmux#5](https://x.test)",
  );
  // A link or code between two mentions makes the second its own.
  expect(dedupeReferences("#5 [see](https://x.test) manaflow-ai/cmux#5", repo)).toBe(
    "#5 [see](https://x.test) manaflow-ai/cmux#5",
  );
  expect(dedupeReferences("#5 `x` manaflow-ai/cmux#5", repo)).toBe("#5 `x` manaflow-ai/cmux#5");
  // Repeats in one bracket go together, and the bracket with them.
  expect(dedupeReferences("#1 (manaflow-ai/cmux#1, #1) done", repo)).toBe("#1 done");
  expect(dedupeReferences("#1 (manaflow-ai/cmux#1, abc1234, #1)", repo)).toBe("#1 (abc1234)");
  // A bracket with the agent's words in it is theirs; an empty bracket they wrote stays.
  expect(dedupeReferences("Reverted #5 (#5 broke main)", repo)).toBe("Reverted #5 (#5 broke main)");
  expect(dedupeReferences("f() #5 (manaflow-ai/cmux#5, #5)", repo)).toBe("f() #5");
  expect(dedupeReferences("Fix #5 [manaflow-ai/cmux#5] broke", repo)).toBe("Fix #5 broke");
  // A fence closes only on its own kind of fence: a ``` line inside a ~~~ block is code.
  const fenced = ["~~~", "```", "#5 manaflow-ai/cmux#5", "~~~", "#5 manaflow-ai/cmux#5"].join("\n");
  expect(dedupeReferences(fenced, repo)).toBe(["~~~", "```", "#5 manaflow-ai/cmux#5", "~~~", "#5"].join("\n"));
});

test("deduping a line is quick whatever it holds", () => {
  const repo = "manaflow-ai/cmux";
  for (const text of [
    `#5 ${"a".repeat(300)}. #5`,
    `#5 ${"abc1234 ".repeat(500)}x #5`,
    Array.from({ length: 5000 }, (_, i) => `#${i}`).join(" "),
    "#5 " + "[".repeat(20000),
  ]) {
    const started = performance.now();
    dedupeReferences(text, repo);
    expect(performance.now() - started).toBeLessThan(200);
  }
});
