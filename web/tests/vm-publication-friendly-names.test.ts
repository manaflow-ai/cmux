import { describe, expect, test } from "bun:test";

import {
  FRIENDLY_LABEL_PATTERN,
  friendlyLabelVocabulary,
  friendlyPublicationLabel,
} from "../services/vm-publications/friendlyNames";

describe("Cloud VM publication friendly names", () => {
  test("mints adjective-colour-animal labels that are valid DNS labels", () => {
    const seen = new Set<string>();
    for (let index = 0; index < 200; index++) {
      const label = friendlyPublicationLabel();
      expect(label).toMatch(FRIENDLY_LABEL_PATTERN);
      expect(label.length).toBeLessThanOrEqual(63);
      seen.add(label);
    }
    // Three dictionaries of hundreds of words: repeats in 200 draws are rare.
    expect(seen.size).toBeGreaterThan(190);
  });

  test("pins the label to a seed for deterministic fixtures", () => {
    const first = friendlyPublicationLabel("publication-seed");
    expect(first).toMatch(FRIENDLY_LABEL_PATTERN);
    expect(friendlyPublicationLabel("publication-seed")).toBe(first);
    expect(friendlyPublicationLabel("another-seed")).not.toBe(first);
  });

  test("keeps every vocabulary word lowercase ASCII, unique, and short enough", () => {
    const dictionaries = friendlyLabelVocabulary();
    expect(dictionaries).toHaveLength(3);
    let longestLabel = 2;
    for (const words of dictionaries) {
      expect(words.length).toBeGreaterThan(20);
      expect(new Set(words).size).toBe(words.length);
      for (const word of words) {
        expect(word).toMatch(/^[a-z]+$/u);
      }
      longestLabel += Math.max(...words.map((word) => word.length));
    }
    expect(longestLabel).toBeLessThanOrEqual(63);
  });
});
