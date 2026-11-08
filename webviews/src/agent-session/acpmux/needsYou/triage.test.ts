// Triage's answer key (needsYou/triage.ts): a tool permission or a plan is allowed once (never for
// the chat), a question takes its first one-click choice, a typed question is only skipped, and
// the strip counts each other waiting chat once.
import { describe, expect, test } from "bun:test";
import type { NeedsYouItem } from "./model";
import { askedAt, othersWaiting, triageMove } from "./triage";

const item = (id: string, sessionId: string, extra: Partial<NeedsYouItem> = {}): NeedsYouItem => ({
  id,
  kind: "approval",
  sessionId,
  ask: id,
  who: { name: sessionId, chief: false },
  answers: [],
  ...extra,
});

const question = { id: "q", items: [] } as unknown as NonNullable<Parameters<typeof triageMove>[0]>["question"];

describe("triageMove", () => {
  test("nothing waiting: no move", () => {
    expect(triageMove(undefined, [])).toBeUndefined();
  });
  test("a tool permission is allowed once, a plan approved", () => {
    expect(triageMove({ permissionId: "p" }, [])).toEqual({ kind: "allow", plan: false });
    expect(triageMove({ permissionId: "p", plan: "1. Do it" }, [])).toEqual({ kind: "allow", plan: true });
  });
  test("a question takes its first one-click choice", () => {
    const asked = item("acpmux:p", "s", {
      kind: "decision",
      answers: [
        { id: "a", label: "Staging", tone: "choice" },
        { id: "b", label: "Local", tone: "choice" },
      ],
    });
    expect(triageMove({ permissionId: "p", question }, [asked])).toEqual({
      kind: "choice",
      item: asked,
      answer: { id: "a", label: "Staging", tone: "choice" },
    });
  });
  test("a question with no one-click answer is only skipped", () => {
    expect(triageMove({ permissionId: "p", question }, [item("acpmux:p", "s", { kind: "decision" })])).toEqual({
      kind: "skip",
    });
    expect(triageMove({ permissionId: "p", question }, [])).toEqual({ kind: "skip" });
  });
});

describe("othersWaiting", () => {
  test("each other chat counts once; this chat and marked tabs never", () => {
    const items = [
      item("acpmux:1", "here"),
      item("acpmux:2", "a"),
      item("acpmux:3", "a"),
      item("chat:b", "b", { kind: "input" }),
      item("tab:t", "", { kind: "tab" }),
    ];
    expect(othersWaiting(items, "here")).toBe(2);
    expect(othersWaiting([], "here")).toBe(0);
  });
});

describe("askedAt", () => {
  test("the time the ask was first seen", () => {
    expect(askedAt({ permissionId: "p" }, [item("acpmux:p", "s", { at: 42 })])).toBe(42);
    expect(askedAt(undefined, [])).toBeUndefined();
  });
});
