import { describe, expect, test } from "bun:test";
import { barState, profileName, refusalMessage } from "./customizeBarModel";

const status = (over: Record<string, unknown> = {}) => ({
  current: { n: 4, kind: "applied", label: "denser sidebar" },
  draft: {
    base: 4,
    started_ms: 1,
    asks: [
      { text: "first", at_ms: 1, origin: "mcp" },
      { text: " theme like Dracula ", at_ms: 2, origin: "mcp" },
    ],
  },
  changes: [
    { path: "themes/dracula.json", part: "themes", kind: "added", by_hand: false },
    { path: "cmux-next.json", part: "settings", kind: "modified", by_hand: false },
  ],
  problems: [],
  skipped: [],
  previewing: true,
  can_apply: true,
  ...over,
});

describe("barState", () => {
  test("a live draft is a preview with its newest wish and parts in order", () => {
    expect(barState(status())).toEqual({
      kind: "preview",
      wish: "theme like Dracula",
      parts: ["settings", "themes"],
      files: 2,
      byHand: false,
      problems: [],
      canApply: true,
      generation: 4,
    });
  });

  test("nothing changed is idle, with the applied generation", () => {
    expect(barState(status({ changes: [], draft: null, previewing: false }))).toEqual({ kind: "idle", generation: 4 });
  });

  test("problems stop an apply and are listed", () => {
    const state = barState(
      status({
        problems: [{ path: "cmux-next.json", part: "settings", line: 3, message: "unknown key" }],
        can_apply: false,
      }),
    );
    expect(state.kind === "preview" && state.canApply).toBe(false);
    expect(state.kind === "preview" && state.problems).toEqual([
      { path: "cmux-next.json", line: 3, message: "unknown key" },
    ]);
  });

  test("a hand edit is flagged; an unknown part is not shown", () => {
    const state = barState(status({ changes: [{ path: "x", part: "future-part", kind: "added", by_hand: true }] }));
    expect(state).toMatchObject({ kind: "preview", parts: [], byHand: true, files: 1 });
  });

  test("a brief's nested status reads the same", () => {
    expect(barState({ brief: "...", begun: true, status: status() }).kind).toBe("preview");
  });

  test("a refusal or nonsense is idle", () => {
    expect(barState({ code: "customize.io", message: "no" })).toEqual({ kind: "idle" });
    expect(barState(null)).toEqual({ kind: "idle" });
    expect(barState("x")).toEqual({ kind: "idle" });
  });
});

test("refusalMessage reads both envelopes", () => {
  expect(refusalMessage({ code: "customize.invalid", message: "fix 1 problem" })).toBe("fix 1 problem");
  expect(refusalMessage({ ok: false, error: { code: "customize.nothing_earlier", message: "" } })).toBe(
    "customize.nothing_earlier",
  );
  expect(refusalMessage(status())).toBeUndefined();
});

test("profileName makes a typed name one the CLI takes", () => {
  expect(profileName(" Night Owl! ")).toBe("night-owl");
  expect(profileName("--x")).toBe("x");
  expect(profileName("!!!")).toBeUndefined();
});
