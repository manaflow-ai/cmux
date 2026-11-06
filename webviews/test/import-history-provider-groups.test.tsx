// https://github.com/manaflow-ai/cmux/issues/36895: Bring your history lists one row per provider. Claude
// (Claude Code chats, Claude memory) and Codex (Codex memories, Codex chats) are each one checkbox with a
// sub-checkbox per source, not four separate rows.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MouseEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    HTMLInputElement: window.HTMLInputElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MouseEvent: window.MouseEvent,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const box = (id: string) => host.querySelector<HTMLInputElement>(`#history-select-${id}`)!;
const label = (id: string) => host.querySelector(`label[for="history-select-${id}"]`)?.textContent;

describe("Bring your history groups local sources by provider", () => {
  test("one Claude row and one Codex row, each with its sources as sub-checkboxes", async () => {
    const { createRoot } = await import("react-dom/client");
    const { ImportHistory } = await import("../src/pages/import-history/ImportHistory");
    const { ImportHistoryStore, initialRows } = await import("../src/pages/import-history/model");
    const { createStrings } = await import("../src/pages/shared/i18n");
    const table = (await import("../src/pages/import-history/generated/strings.json")).default;
    // This Mac has every source but Codex chats; all found sources start checked.
    const rows = initialRows().map((row) =>
      row.kind === "local" && row.id !== "codex-sessions" ? { ...row, source: row.id, selected: true } : row,
    );
    const store = new ImportHistoryStore(
      { call: async () => ({}) as never },
      { phase: "ready", rows, canUndo: false, undoing: false },
    );
    root = createRoot(host);
    act(() => root!.render(<ImportHistory store={store} strings={createStrings(table, ["en"])} />));

    // Two provider cards where four source cards were; each lists its own sources under it.
    const providers = [...host.querySelectorAll(".history-provider")];
    expect(providers.map((card) => card.querySelector(".history-source-line label")?.textContent)).toEqual([
      "Claude",
      "Codex",
    ]);
    expect(
      providers.map((card) =>
        [...card.querySelectorAll(".history-provider-sources label")].map((node) => node.textContent),
      ),
    ).toEqual([
      ["Claude Code chats", "Claude memory"],
      ["Codex memories", "Codex chats"],
    ]);
    for (const id of ["claude-code", "claude-memory", "codex", "codex-sessions"])
      expect(host.querySelector(`.history-source #history-select-${id}`)?.closest(".history-provider")).not.toBeNull();
    expect(label("claude-local")).toBe("Claude");
    expect(box("codex-sessions").disabled).toBe(true);

    // Unchecking one source leaves its provider partly checked.
    act(() => box("claude-memory").click());
    expect(box("claude-local").checked).toBe(false);
    expect(box("claude-local").indeterminate).toBe(true);

    // The provider checkbox checks all of its found sources again, then clears them.
    act(() => box("claude-local").click());
    expect([box("claude-code").checked, box("claude-memory").checked]).toEqual([true, true]);
    expect(box("claude-local").indeterminate).toBe(false);
    act(() => box("codex-local").click());
    expect([box("codex").checked, box("codex-sessions").checked, box("codex-local").checked]).toEqual([
      false,
      false,
      false,
    ]);
    // Checking Codex again does not pick the Codex chats this Mac does not have.
    act(() => box("codex-local").click());
    expect([box("codex").checked, box("codex-sessions").checked, box("codex-local").checked]).toEqual([
      true,
      false,
      true,
    ]);
  });
});
