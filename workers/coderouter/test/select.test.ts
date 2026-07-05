import { describe, expect, test } from "bun:test";
import { scoreCandidate, selectCredential } from "../src/select";

const now = 1_000_000;
const state = (usedPercent: number, resetAfterSeconds = 100) => ({
  windows: [{ name: "short", usedPercent, limitWindowSeconds: 3600, resetAfterSeconds }],
});

describe("selection", () => {
  test("prioritizes usable oauth over byok and managed", () => {
    const selected = selectCredential(
      [
        { id: "m", class: "managed", assignmentCount: 0, limitState: { windows: [] } },
        { id: "o", class: "oauth", assignmentCount: 5, limitState: state(20) },
        { id: "b", class: "byok", assignmentCount: 0, limitState: { windows: [] } },
      ],
      now,
    );
    expect(selected?.id).toBe("o");
  });

  test("uses byok before oauth below the 40 percent floor", () => {
    const selected = selectCredential(
      [
        { id: "o", class: "oauth", assignmentCount: 0, limitState: state(70) },
        { id: "b", class: "byok", assignmentCount: 0, limitState: { windows: [] } },
      ],
      now,
    );
    expect(selected?.id).toBe("b");
    expect(scoreCandidate({ id: "o", class: "oauth", assignmentCount: 0, limitState: state(70) }, now).tier).toBe(3);
  });

  test("tie-breaks by expiry pressure, headroom, assignment count, then id", () => {
    expect(
      selectCredential(
        [
          { id: "a", class: "oauth", assignmentCount: 0, limitState: state(20, 200) },
          { id: "b", class: "oauth", assignmentCount: 0, limitState: state(20, 100) },
        ],
        now,
      )?.id,
    ).toBe("b");

    expect(
      selectCredential(
        [
          { id: "b", class: "oauth", assignmentCount: 2, limitState: state(20, 100) },
          { id: "a", class: "oauth", assignmentCount: 1, limitState: state(20, 100) },
        ],
        now,
      )?.id,
    ).toBe("a");
  });

  test("excludes cooldown candidates", () => {
    const selected = selectCredential(
      [{ id: "o", class: "oauth", assignmentCount: 0, limitState: { ...state(0), cooldownUntil: now + 1000 } }],
      now,
    );
    expect(selected).toBeNull();
  });

  test("returns exhausted oauth by window as last resort but still refuses cooldown", () => {
    const exhaustedByWindow = selectCredential(
      [{ id: "o", class: "oauth", assignmentCount: 0, limitState: state(100) }],
      now,
    );
    expect(exhaustedByWindow?.id).toBe("o");
    expect(exhaustedByWindow?.tier).toBe(4);

    const cooldownExhausted = selectCredential(
      [{ id: "o", class: "oauth", assignmentCount: 0, limitState: { ...state(100), cooldownUntil: now + 1000 } }],
      now,
    );
    expect(cooldownExhausted).toBeNull();
  });
});
