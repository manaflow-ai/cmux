import { describe, expect, test } from "bun:test";
import {
  allocateVmSlug,
  generateVmSlug,
  isVmSlug,
  suffixVmSlug,
  VM_SLUG_ADJECTIVES,
  VM_SLUG_ANIMALS,
  VM_SLUG_BANNED_WORDS,
  VM_SLUG_COLORS,
  VM_SLUG_PATTERN,
  VM_SLUG_PLAIN_ATTEMPTS,
  VM_SLUG_SUFFIX_ATTEMPTS,
} from "../services/vms/vmNaming";

const WORD = /^[a-z]{2,12}$/;

describe("vm slug word lists", () => {
  test("every word is lowercase ascii, unique across lists, and not banned", () => {
    const seen = new Map<string, string>();
    for (const [list, words] of [
      ["adjective", VM_SLUG_ADJECTIVES],
      ["color", VM_SLUG_COLORS],
      ["animal", VM_SLUG_ANIMALS],
    ] as const) {
      for (const word of words) {
        expect(word).toMatch(WORD);
        expect(VM_SLUG_BANNED_WORDS.has(word)).toBe(false);
        const prior = seen.get(word);
        if (prior) throw new Error(`${word} is in both ${prior} and ${list}`);
        seen.set(word, list);
      }
    }
    // Enough combinations that a per-team collision is a retry, not a plan.
    expect(VM_SLUG_ADJECTIVES.length * VM_SLUG_COLORS.length * VM_SLUG_ANIMALS.length).toBeGreaterThan(100_000);
  });
});

describe("generateVmSlug", () => {
  test("produces adjective-color-animal that matches the pattern", () => {
    for (let i = 0; i < 500; i += 1) {
      const slug = generateVmSlug();
      expect(slug).toMatch(VM_SLUG_PATTERN);
      const [adjective, color, animal] = slug.split("-");
      expect(VM_SLUG_ADJECTIVES).toContain(adjective);
      expect(VM_SLUG_COLORS).toContain(color);
      expect(VM_SLUG_ANIMALS).toContain(animal);
    }
  });

  test("is deterministic under an injected random source", () => {
    const zero = () => 0;
    expect(generateVmSlug(zero)).toBe(`${VM_SLUG_ADJECTIVES[0]}-${VM_SLUG_COLORS[0]}-${VM_SLUG_ANIMALS[0]}`);
    expect(suffixVmSlug("sleepy-teal-otter", zero)).toBe("sleepy-teal-otter-aaaa");
    expect(isVmSlug("sleepy-teal-otter-aaaa")).toBe(true);
  });
});

describe("isVmSlug", () => {
  test("rejects anything outside the url-safe grammar", () => {
    for (const bad of ["", "Sleepy-Teal-Otter", "sleepy teal otter", "sleepy-teal", "a-b-c-d-e", "sleepy--teal-otter", "sleepy-teal-otter-", "sleepy-teal-otter-ab", 42, null]) {
      expect(isVmSlug(bad)).toBe(false);
    }
    expect(isVmSlug("sleepy-teal-otter")).toBe(true);
  });
});

describe("allocateVmSlug", () => {
  test("returns the first free plain candidate", async () => {
    const asked: string[] = [];
    const slug = await allocateVmSlug(async (candidate) => {
      asked.push(candidate);
      return asked.length < 3;
    });
    expect(asked).toHaveLength(3);
    expect(slug).toBe(asked[2]);
    expect(slug).toMatch(/^[a-z]+-[a-z]+-[a-z]+$/);
  });

  test("falls back to a suffixed candidate once every plain one is taken", async () => {
    const asked: string[] = [];
    const slug = await allocateVmSlug(async (candidate) => {
      asked.push(candidate);
      // Plain candidates have three words; only the suffixed one has four.
      return candidate.split("-").length === 3;
    });
    expect(asked).toHaveLength(VM_SLUG_PLAIN_ATTEMPTS + 1);
    expect(slug).toMatch(VM_SLUG_PATTERN);
    expect(slug.startsWith(asked[VM_SLUG_PLAIN_ATTEMPTS - 1]!)).toBe(true);
  });

  test("fails after a bounded suffix search", async () => {
    const asked: string[] = [];
    await expect(allocateVmSlug(async (candidate) => {
      asked.push(candidate);
      return true;
    })).rejects.toThrow("Unable to allocate a unique VM slug");
    expect(asked).toHaveLength(VM_SLUG_PLAIN_ATTEMPTS + VM_SLUG_SUFFIX_ATTEMPTS);
  });
});
