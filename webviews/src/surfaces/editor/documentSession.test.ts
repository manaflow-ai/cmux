import { describe, expect, test } from "bun:test";
import { DocumentSession } from "./documentSession";

describe("DocumentSession", () => {
  test("clean buffer silently reloads on external change", () => {
    const session = new DocumentSession("a");
    const action = session.applyExternal("a", "b");
    expect(action).toEqual({ kind: "replaceBuffer", content: "b" });
    expect(session.isDirty("b")).toBe(false);
    expect(session.hasPendingConflict()).toBe(false);
  });

  test("dirty buffer keeps edits and flags a conflict; dirty is measured against new disk content", () => {
    const session = new DocumentSession("a");
    expect(session.isDirty("a edited")).toBe(true);
    const action = session.applyExternal("a edited", "b");
    expect(action).toEqual({ kind: "showConflict" });
    expect(session.hasPendingConflict()).toBe(true);
    expect(session.isDirty("a edited")).toBe(true);
    expect(session.isDirty("b")).toBe(false);
  });

  test("external change matching the buffer is a no-op echo", () => {
    const session = new DocumentSession("a");
    const action = session.applyExternal("b", "b");
    expect(action).toEqual({ kind: "none" });
    expect(session.isDirty("b")).toBe(false);
  });

  test("echo external change clears a pending conflict when contents converge", () => {
    const session = new DocumentSession("a");
    session.applyExternal("a edited", "b");
    expect(session.hasPendingConflict()).toBe(true);
    const action = session.applyExternal("b", "b");
    expect(action).toEqual({ kind: "none" });
    expect(session.hasPendingConflict()).toBe(false);
  });

  test("save moves the baseline and clears any conflict", () => {
    const session = new DocumentSession("a");
    session.applyExternal("a edited", "b");
    session.noteSaved("a edited");
    expect(session.hasPendingConflict()).toBe(false);
    expect(session.isDirty("a edited")).toBe(false);
    expect(session.isDirty("b")).toBe(true);
  });

  test("conflict reload returns disk content and clears the conflict", () => {
    const session = new DocumentSession("a");
    session.applyExternal("a edited", "b");
    expect(session.resolveConflictReload()).toBe("b");
    expect(session.hasPendingConflict()).toBe(false);
    expect(session.isDirty("b")).toBe(false);
  });

  test("keep-mine dismisses the banner but stays dirty", () => {
    const session = new DocumentSession("a");
    session.applyExternal("a edited", "b");
    session.resolveConflictKeepMine();
    expect(session.hasPendingConflict()).toBe(false);
    expect(session.isDirty("a edited")).toBe(true);
  });
});
