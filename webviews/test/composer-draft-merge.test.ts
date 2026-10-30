import { expect, test } from "bun:test";
import vectors from "./fixtures/composer-draft-merge.json";
import { mergedDraft } from "../src/agent-session/acpmux/composerDraft";

const expand = (parts: { text: string; count: number }[]) => parts.map(({ text, count }) => text.repeat(count)).join("");

for (const vector of vectors) {
  test(`shared draft merge: ${vector.name}`, () => {
    expect(mergedDraft(expand(vector.typed), expand(vector.kept))).toBe(expand(vector.expected));
  });
}

test("merging million-character drafts stays within the main-thread budget", () => {
  const vector = vectors.find(({ name }) => name === "one million adversarial")!;
  const typed = expand(vector.typed);
  const kept = expand(vector.kept);
  const start = performance.now();
  const merged = mergedDraft(typed, kept);
  const elapsed = performance.now() - start;
  expect(merged).toBe(expand(vector.expected));
  console.info(`draft merge: 1M characters per input, ${elapsed.toFixed(2)} ms`);
  // Generous across CI runners, but catches the previous quadratic scan's multi-second stall.
  expect(elapsed).toBeLessThan(500);
});
