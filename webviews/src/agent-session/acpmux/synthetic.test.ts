import { describe, expect, test } from "bun:test";
import { syntheticRows } from "./synthetic";

describe("synthetic transcript", () => {
  test("count / 3 turns of user, assistant and turn summary", () => {
    const rows = syntheticRows(5000);
    expect(rows.length).toBe(4998);
    expect(rows.slice(0, 3).map((row) => row.kind)).toEqual(["user", "assistant", "turnSummary"]);
    expect(new Set(rows.map((row) => row.id)).size).toBe(rows.length);
    expect(rows.every((row, index) => row.at === (index + 1) * 1_000 && row.version === 1)).toBe(true);
    expect(syntheticRows(1).length).toBe(3);
  });

  test("answers vary in length, with a list every third turn and code every seventh", () => {
    const answers = syntheticRows(63)
      .filter((row) => row.kind === "assistant")
      .map((row) => row.text ?? "");
    expect(answers[0]).toBe(
      `Answer 0. This sentence adds some width to the paragraph. \n\n- first point\n- second point\n- third point\n\n\`\`\`swift\nlet value = 0\nprint(value)\n\`\`\``,
    );
    expect(answers[1]).toBe("Answer 1. " + "This sentence adds some width to the paragraph. ".repeat(2));
    expect(answers[3]).toContain("- third point");
    expect(answers[3]).not.toContain("```");
    expect(answers[7]).toContain("let value = 7");
    expect(answers[7]).not.toContain("- first point");
    expect(answers[4].split("This sentence").length - 1).toBe(5);
  });

  test("deterministic", () => {
    expect(syntheticRows(300)).toEqual(syntheticRows(300));
    expect(syntheticRows(6)[0].text).toBe("Question 0: how should the transcript handle item 0?");
  });
});
