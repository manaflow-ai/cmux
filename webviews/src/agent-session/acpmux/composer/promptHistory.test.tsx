import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { usePromptHistory } from "./promptHistory";

let dom: JSDOM | undefined;
let root: Root | undefined;
let history: ReturnType<typeof usePromptHistory> | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function prompt(id: string, text: string): AcpmuxRow {
  return { id, version: 1, at: 0, kind: "user", text };
}

function Harness({ rows }: { rows: readonly AcpmuxRow[] }) {
  history = usePromptHistory(rows);
  return null;
}

function render(rows: readonly AcpmuxRow[]) {
  if (!dom) {
    dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
    for (const key of ["window", "document", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
    Object.assign(scope, {
      window: dom.window,
      document: dom.window.document,
      IS_REACT_ACT_ENVIRONMENT: true,
    });
  }
  if (!root) {
    const container = dom.window.document.getElementById("root");
    if (!container) throw new Error("test root is missing");
    root = createRoot(container);
  }
  act(() => root?.render(<Harness rows={rows} />));
}

function currentHistory() {
  if (!history) throw new Error("history hook is not mounted");
  return history;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  history = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

describe("prompt history paging", () => {
  test("keeps the recalled row anchored when an older page is prepended", () => {
    const initial = [prompt("b", "B"), prompt("c", "C")];
    render(initial);
    expect(currentHistory().step(-1, "")).toBe("C");
    render([prompt("a", "A"), ...initial]);
    expect(currentHistory().step(-1, "C")).toBe("B");

    render(initial);
    expect(currentHistory().step(-1, "")).toBe("C");
    expect(currentHistory().step(-1, "C")).toBe("B");
    render([prompt("a", "A"), ...initial]);
    expect(currentHistory().step(-1, "B")).toBe("A");
  });

  test("merges duplicate text at an older page boundary", () => {
    const current = [prompt("b", "same"), prompt("c", "new")];
    render(current);
    expect(currentHistory().step(-1, "")).toBe("new");
    render([prompt("older-b", "same"), ...current]);
    expect(currentHistory().step(-1, "new")).toBe("same");
    expect(currentHistory().step(-1, "same")).toBeNull();
  });

  test("keeps repeated non-adjacent prompts as separate history steps", () => {
    render([prompt("a1", "A"), prompt("b", "B"), prompt("a2", "A")]);
    expect(currentHistory().step(-1, "")).toBe("A");
    expect(currentHistory().step(-1, "A")).toBe("B");
    expect(currentHistory().step(-1, "B")).toBe("A");
    expect(currentHistory().step(1, "A")).toBe("B");
  });

  test("sees appended prompts when moving forward", () => {
    const initial = [prompt("a", "A"), prompt("b", "B")];
    render(initial);
    expect(currentHistory().step(-1, "")).toBe("B");
    render([...initial, prompt("c", "C")]);
    expect(currentHistory().step(1, "B")).toBe("C");
  });

  test("ends browsing when its anchor row disappears", () => {
    render([prompt("a", "A"), prompt("b", "B")]);
    expect(currentHistory().step(-1, "")).toBe("B");
    render([prompt("a", "A"), prompt("c", "C")]);
    expect(currentHistory().showing(() => "B")).toBe(false);
    expect(currentHistory().step(-1, "B")).toBeUndefined();
  });

  test("does not replace an edited recalled draft", () => {
    render([prompt("a", "A"), prompt("b", "B")]);
    expect(currentHistory().step(-1, "")).toBe("B");
    expect(currentHistory().step(-1, "edited draft")).toBeUndefined();
  });

  test("an edit that ends browsing drops the anchor, so undoing the edit stays a draft", () => {
    render([prompt("a", "A"), prompt("b", "B")]);
    expect(currentHistory().step(-1, "")).toBe("B");
    expect(currentHistory().step(-1, "Bx")).toBeUndefined();
    // Deleting the "x" again shows "B", but it is now the person's draft: ↓ must not erase it.
    expect(currentHistory().showing(() => "B")).toBe(false);
    expect(currentHistory().step(1, "B")).toBeUndefined();
  });
});
