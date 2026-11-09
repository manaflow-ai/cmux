// What a change to the window's toasts does to each one (planToasts, pure).
import { describe, expect, test } from "bun:test";
import type { ToastState } from "./types";
import { readToastsState } from "./types";
import { planToasts } from "./useToastMotion";

const toast = (serial: number, id = `t${serial}`): ToastState => ({
  serial,
  id,
  message: id,
  closable: true,
  showsDetails: false,
  showsUndoKey: false,
});

describe("planToasts", () => {
  test("a new toast arrives; one that ends fades", () => {
    const a = toast(1);
    const b = toast(2);
    expect(planToasts([a], [a, b])).toEqual({ appear: [2], inPlace: [], exit: [], drop: [] });
    expect(planToasts([a, b], [b])).toEqual({ appear: [], inPlace: [], exit: [a], drop: [] });
  });

  test("the newest toast's successor under its id takes its slot in one frame", () => {
    const old = toast(1, "update");
    const next = toast(2, "update");
    expect(planToasts([old], [next])).toEqual({ appear: [], inPlace: [2], exit: [], drop: [old] });
  });

  test("an older toast replaced under its id goes at once; its successor arrives at the bottom", () => {
    const old = toast(1, "copy");
    const other = toast(2);
    const next = toast(3, "copy");
    expect(planToasts([old, other], [other, next])).toEqual({ appear: [3], inPlace: [], exit: [], drop: [old] });
  });

  test("a fourth toast pushes the oldest out: it fades while the new one arrives", () => {
    const [a, b, c, d] = [toast(1), toast(2), toast(3), toast(4)];
    expect(planToasts([a, b, c], [b, c, d])).toEqual({ appear: [4], inPlace: [], exit: [a], drop: [] });
  });
});

describe("readToastsState", () => {
  test("drops malformed toasts and keeps the newest three", () => {
    const state = readToastsState({
      floor: 24,
      toasts: [
        { serial: 1, id: "a", message: "a" },
        { id: "bad" },
        { serial: 2, id: "b", message: "b", action: { title: "Details", revealsDetails: true }, showsDetails: true },
        { serial: 3, id: "c", message: "c", showsUndoKey: true },
        { serial: 4, id: "d", message: "d", action: { title: "Undo", isUndo: true }, showsUndoKey: true },
      ],
    });
    expect(state.floor).toBe(24);
    expect(state.toasts.map((item) => item.serial)).toEqual([2, 3, 4]);
    expect(state.toasts[0]?.showsDetails).toBe(true);
    // Only an undo toast shows the key.
    expect(state.toasts[1]?.showsUndoKey).toBe(false);
    expect(state.toasts[2]?.showsUndoKey).toBe(true);
  });

  test("anything else reads as no toasts", () => {
    expect(readToastsState(null)).toEqual({ toasts: [], floor: 0 });
    expect(readToastsState({ floor: -3, toasts: "x" })).toEqual({ toasts: [], floor: 0 });
    // Review 2 of #37289 (F3): an empty entry is dropped, not read.
    expect(readToastsState({ toasts: [null, undefined, 3] })).toEqual({ toasts: [], floor: 0 });
  });
});
