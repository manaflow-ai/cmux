import { describe, expect, test } from "bun:test";

import {
  FRIENDLY_LABEL_PATTERN,
  friendlyLabelVocabulary,
  friendlyPublicationLabel,
} from "../services/vm-publications/friendlyNames";

describe("Cloud VM publication friendly names", () => {
  test("mints descriptor-colour-animal labels that are valid DNS labels", () => {
    for (let index = 0; index < 200; index++) {
      const label = friendlyPublicationLabel();
      expect(label).toMatch(FRIENDLY_LABEL_PATTERN);
      expect(label.length).toBeLessThanOrEqual(63);
    }
    expect(friendlyPublicationLabel(() => 0)).toBe("amused-amber-badgers");
    const last = (max: number) => max - 1;
    expect(friendlyPublicationLabel(last)).toBe("zesty-yellow-zebras");
  });

  test("keeps every vocabulary word lowercase, unique, and short", () => {
    const { descriptors, colors, animals } = friendlyLabelVocabulary();
    for (const words of [descriptors, colors, animals]) {
      expect(new Set(words).size).toBe(words.length);
      for (const word of words) {
        expect(word).toMatch(/^[a-z]{3,12}$/u);
      }
    }
    const longest = (words: readonly string[]) =>
      Math.max(...words.map((word) => word.length));
    expect(longest(descriptors) + longest(colors) + longest(animals) + 2)
      .toBeLessThanOrEqual(40);
  });

  test("rejects a random source that leaves the vocabulary", () => {
    expect(() => friendlyPublicationLabel(() => 99)).toThrow(/out-of-range/u);
    expect(() => friendlyPublicationLabel(() => -1)).toThrow(/out-of-range/u);
  });
});
