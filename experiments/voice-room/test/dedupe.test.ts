import { describe, expect, test } from "bun:test";
import { CrossMicDedupe, similarity } from "../src/dedupe.ts";

describe("CrossMicDedupe", () => {
  test("a quieter copy of the same sentence from another mic in the room is dropped", () => {
    const dedupe = new CrossMicDedupe();
    const first = { speaker: "ana", text: "Let's ship the build tonight.", at: 1000, level: 0.8 };
    expect(dedupe.check(first).kind).toBe("new");
    dedupe.remember({ ...first, entryId: 1 });
    expect(dedupe.check({ speaker: "bo", text: "lets ship the build tonight", at: 1800, level: 0.2 }).kind).toBe("duplicate");
  });

  test("a louder copy takes the line over: that mic is the speaker's own", () => {
    const dedupe = new CrossMicDedupe();
    dedupe.remember({ speaker: "bo", text: "open the pull request", at: 0, level: 0.1, entryId: 7 });
    const verdict = dedupe.check({ speaker: "ana", text: "Open the pull request.", at: 900, level: 0.9 });
    expect(verdict).toEqual({ kind: "replace", previous: { speaker: "bo", text: "open the pull request", at: 0, level: 0.1, entryId: 7 } });
  });

  test("the same person repeating themselves, or lines far apart, are kept", () => {
    const dedupe = new CrossMicDedupe();
    dedupe.remember({ speaker: "ana", text: "yes do it", at: 0, level: 0.5, entryId: 1 });
    expect(dedupe.check({ speaker: "ana", text: "yes do it", at: 500, level: 0.5 }).kind).toBe("new");
    expect(dedupe.check({ speaker: "bo", text: "yes do it", at: 10_000, level: 0.1 }).kind).toBe("new");
    expect(similarity("fix the login page", "order lunch")).toBe(0);
  });
});
