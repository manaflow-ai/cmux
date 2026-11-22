// l10n-allow-file: test fixtures, not shipped UI.
import { describe, expect, test } from "bun:test";
import { chosenAnswer, nextStepAsk } from "./nextStepAsk";

describe("nextStepAsk", () => {
  test("a tagged yes-or-no question gets Yes and Not now, its tail as the muted line", () => {
    const ask = nextStepAsk(
      "Done with the sweep.\n\n[irreversible] Should I remove the branch allowlist on the dev image? It's a deployment-trust setting.",
    );
    expect(ask).toEqual({
      tag: "irreversible",
      question: "Should I remove the branch allowlist on the dev image?",
      detail: "It's a deployment-trust setting.",
      options: [
        { label: "Yes", key: "recap.yes" },
        { label: "Not now", key: "recap.notNow" },
      ],
      rest: "Done with the sweep.",
    });
  });

  test("a list under the line is its answers, first is primary; the lines leave the prose", () => {
    const ask = nextStepAsk(
      "Recap.\n\n**[taste]** For Leo: which tab style?\n- Chrome tabs\n- Safari tabs\n- **Pills**\n\nThanks.",
    );
    expect(ask?.question).toBe("Which tab style?");
    expect(ask?.options.map((option) => option.label)).toEqual(["Chrome tabs", "Safari tabs", "Pills"]);
    expect(ask?.rest).toBe("Recap.\n\nThanks.");
  });

  test("a blank line between the question and its list is fine, as is [for you] and a numbered list", () => {
    const ask = nextStepAsk("[for you] Which build first?\n\n1. Nightly\n2. DEV");
    expect(ask?.tag).toBe("for you");
    expect(ask?.options.map((option) => option.label)).toEqual(["Nightly", "DEV"]);
  });

  test("ordinary prose and mentions of the tags draw nothing", () => {
    for (const text of [
      "Ran the tests; all green. Should I merge?",
      "Tag such an ask's line `[taste]`, like `[taste] For Leo: which of these two tab styles?`",
      "Possible [outward] items: should we?",
      "- [outward] huge-blue fleet trust-list entry (older).",
      "[irreversible] For Leo: reboot to reclaim memory once the source is fixed.",
      "```\n[taste] Should I?\n```",
      "> [taste] Should I?",
      "[taste] Which of these two tab styles?",
      "[taste] Pick one?\n- only one",
      `[taste] Pick one?\n- a\n- b\n- c\n- d\n- e`,
      `[taste] Pick one?\n- ${"x".repeat(81)}\n- b`,
      undefined,
      "",
    ])
      expect(nextStepAsk(text)).toBeUndefined();
  });

  test("two tagged questions draw none: a button could not say which it answers", () => {
    expect(nextStepAsk("[outward] Should I post it?\n[taste] Should it be blue?")).toBeUndefined();
  });

  test("a question mark inside inline code is not the question's end", () => {
    const ask = nextStepAsk("[outward] Should I run `rm f/*?` on cosmic? Only stale dirs.");
    expect(ask?.question).toBe("Should I run `rm f/*?` on cosmic?");
    expect(ask?.detail).toBe("Only stale dirs.");
  });
});

describe("chosenAnswer", () => {
  const ask = nextStepAsk("[taste] Which look?\n- Box\n- Inline")!;
  test("the option the prompt chose, in the option's own words", () => {
    expect(chosenAnswer(ask, "  inline ")).toBe("Inline");
  });
  test("a typed answer reads as its first line", () => {
    expect(chosenAnswer(ask, "Neither, try chips\nand smaller")).toBe("Neither, try chips");
  });
});
