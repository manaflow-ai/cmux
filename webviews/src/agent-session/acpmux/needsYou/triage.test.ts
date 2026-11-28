// Triage's answer key (needsYou/triage.ts): a tool permission or a plan is allowed once (never for
// the chat), a question takes its first one-click choice, a typed question is only skipped, and
// the strip counts each other waiting chat once.
import { describe, expect, test } from "bun:test";
import type { AcpmuxPermission } from "../model";
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

const once: AcpmuxPermission["options"] = [{ id: "a", name: "Allow", kind: "allow_once", allow: true }];

const question = { id: "q", items: [] } as unknown as NonNullable<Parameters<typeof triageMove>[0]>["question"];

describe("triageMove", () => {
  test("nothing waiting: no move", () => {
    expect(triageMove(undefined, [])).toBeUndefined();
  });
  test("a tool permission is allowed once, a plan approved", () => {
    expect(triageMove({ permissionId: "p", options: once }, [])).toEqual({
      kind: "allow",
      plan: false,
    });
    expect(triageMove({ permissionId: "p", plan: "1. Do it", options: once }, [])).toEqual({
      kind: "allow",
      plan: true,
    });
  });
  test("an ask that offers no Allow once is only skipped", () => {
    expect(triageMove({ permissionId: "p", options: [] }, [])).toEqual({ kind: "skip" });
    expect(
      triageMove(
        {
          permissionId: "p",
          options: [{ id: "r", name: "Reject", kind: "reject_once", allow: false }],
        },
        [],
      ),
    ).toEqual({ kind: "skip" });
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

describe("triageMove follow-ups (#38526 review)", () => {
  const choiceQuestion = {
    id: "q",
    source: { session: "s", permission: "p" },
    items: [
      {
        id: "i",
        question: "Which?",
        options: [
          { id: "a", label: "Staging" },
          { id: "b", label: "Local" },
        ],
      },
    ],
  } as unknown as NonNullable<Parameters<typeof triageMove>[0]>["question"];
  test("F2: with the Needs you list off, a question still takes its first choice", () => {
    const move = triageMove({ permissionId: "p", question: choiceQuestion }, [], "s");
    expect(move?.kind).toBe("choice");
    if (move?.kind !== "choice") return;
    expect(move.answer).toEqual({ id: "a", label: "Staging", tone: "choice" });
    expect(move.item).toMatchObject({
      sessionId: "s",
      permissionId: "p",
      question: choiceQuestion,
    });
  });
  test("F1: a pending permission group is allowed once through its panel", () => {
    const group = (state: string, decisions: string[]) => ({ state, decisions }) as never;
    expect(
      triageMove(undefined, [], "s", {
        supported: true,
        groups: [group("pending", ["allow_once", "deny"])],
      }),
    ).toEqual({
      kind: "allow",
      plan: false,
    });
    // Nothing a key may allow: a group still collecting, one acpmux refuses allows for, or none.
    expect(
      triageMove(undefined, [], "s", {
        supported: true,
        groups: [group("collecting", ["allow_once"])],
      }),
    ).toBeUndefined();
    expect(
      triageMove(undefined, [], "s", {
        supported: true,
        allowRefused: "web control",
        groups: [group("pending", ["allow_once"])],
      }),
    ).toBeUndefined();
    expect(triageMove(undefined, [], "s", { supported: false, groups: [] })).toBeUndefined();
  });
  test("a plan or tool ask beside a waiting group is only skipped: the group's panel takes the key", () => {
    const group = (state: string) => ({ state, decisions: ["allow_once"] }) as never;
    for (const state of ["pending", "collecting"]) {
      const groups = { supported: true, groups: [group(state)] };
      expect(triageMove({ permissionId: "p", plan: "1. Do it", options: once }, [], "s", groups)).toEqual({
        kind: "skip",
      });
      expect(triageMove({ permissionId: "p", options: once }, [], "s", groups)).toEqual({ kind: "skip" });
    }
    // With no group waiting, the card takes the key again.
    expect(
      triageMove({ permissionId: "p", plan: "1. Do it", options: once }, [], "s", {
        supported: true,
        groups: [group("answered")],
      }),
    ).toEqual({ kind: "allow", plan: true });
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
