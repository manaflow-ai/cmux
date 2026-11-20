// LineReveal over a fake Monaco editor: a Find result or a file link far right on a long line
// scrolls sideways to its column, and the editor takes the page's keyboard focus, as base's
// MonacoView.reveal did before the line jump replaced it.
import { expect, test } from "bun:test";
import type { editor } from "monaco-editor/editor/editor.api.js";
import { LineReveal } from "./lineReveal";

function fakeEditor(lines: string[]) {
  const calls: string[] = [];
  const centered: { lineNumber: number; column: number }[] = [];
  const model = {
    getLineCount: () => lines.length,
    getLineMaxColumn: (line: number) => (lines[line - 1]?.length ?? 0) + 1,
  };
  const fake = {
    getModel: () => model,
    setPosition: () => void calls.push("setPosition"),
    revealPositionInCenter: (position: { lineNumber: number; column: number }) => {
      calls.push("revealPositionInCenter");
      centered.push(position);
    },
    revealLineInCenter: () => void calls.push("revealLineInCenter"),
    focus: () => void calls.push("focus"),
    getLayoutInfo: () => ({ height: 400 }),
    onDidLayoutChange: () => ({ dispose() {} }),
    createDecorationsCollection: () => ({ clear() {} }),
  };
  return { editor: fake as unknown as editor.IStandaloneCodeEditor, calls, centered };
}

test("a reveal far right on a long line centers its column, not only its line", () => {
  const fake = fakeEditor(["short", `${"x".repeat(400)}match`]);
  const reveal = new LineReveal(fake.editor);
  reveal.reveal({ line: 2, column: 401 });
  expect(fake.centered).toEqual([{ lineNumber: 2, column: 401 }]);
  expect(fake.calls).not.toContain("revealLineInCenter");
  reveal.clear();
});

test("a reveal puts the page's keyboard focus in the editor", () => {
  const fake = fakeEditor(["one", "two"]);
  const reveal = new LineReveal(fake.editor);
  reveal.reveal({ line: 2 });
  expect(fake.calls).toContain("focus");
  reveal.clear();
});
