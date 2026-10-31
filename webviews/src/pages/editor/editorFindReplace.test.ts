// Opt-Cmd-F (Replace) opens the shared find pill with its replace row instead of Monaco's
// find-and-replace widget (Lawrence, 2026-10-20). EditorFind over a fake editor whose text the
// replacements change.
import { expect, test } from "bun:test";
import { EditorFind, type FindRange, type FindTarget } from "./editorFind";

function fakeEditor(initial: string[], readOnly = false) {
  const lines = [...initial];
  let undoStops = 0;
  const target: FindTarget = {
    findMatches(query, matchCase) {
      const out: FindRange[] = [];
      lines.forEach((line, i) => {
        const hay = matchCase ? line : line.toLowerCase();
        const needle = matchCase ? query : query.toLowerCase();
        for (let at = hay.indexOf(needle); at >= 0; at = hay.indexOf(needle, at + needle.length)) {
          out.push({
            startLineNumber: i + 1,
            startColumn: at + 1,
            endLineNumber: i + 1,
            endColumn: at + 1 + query.length,
          });
        }
      });
      return out;
    },
    caret: () => ({ lineNumber: 1, column: 1 }),
    selectedText: () => "",
    show: () => undefined,
    focus: () => undefined,
    readOnly: () => readOnly,
    replace(ranges, text) {
      undoStops++;
      // Right to left, so earlier ranges keep their columns.
      for (const range of [...ranges].sort(
        (a, b) => b.startLineNumber - a.startLineNumber || b.startColumn - a.startColumn,
      )) {
        const line = lines[range.startLineNumber - 1];
        lines[range.startLineNumber - 1] =
          line.slice(0, range.startColumn - 1) + text + line.slice(range.endColumn - 1);
      }
    },
  };
  return { target, lines, undoStops: () => undoStops };
}

test("Replace opens the pill with its replace row", () => {
  const editor = fakeEditor(["a"]);
  const find = new EditorFind();
  find.attach(editor.target);
  find.showReplace();
  expect(find.getState().open).toBe(true);
  expect(find.getState().replaceOpen).toBe(true);
  // Plain Cmd-F afterwards keeps the row (Monaco's behavior); hiding drops it.
  find.show();
  expect(find.getState().replaceOpen).toBe(true);
  find.hide();
  find.show();
  expect(find.getState().replaceOpen).toBe(false);
});

test("Replace swaps the active match and moves to the next one", () => {
  const editor = fakeEditor(["foo foo foo"]);
  const find = new EditorFind();
  find.attach(editor.target);
  find.showReplace("foo");
  find.setReplacement("bar");
  find.next();
  find.replace();
  expect(editor.lines[0]).toBe("foo bar foo");
  expect(find.getState().matches).toHaveLength(2);
  // The match after the replaced one is now active.
  expect(find.getState().active).toBe(1);
});

test("Replace All replaces matches beyond the pill's own limit", () => {
  const editor = fakeEditor(["x x x x"]);
  const find = new EditorFind();
  const pillOnly = {
    ...editor.target,
    findMatches: (q: string, c: boolean, all?: boolean) => {
      const found = editor.target.findMatches(q, c);
      return all ? found : found.slice(0, 2);
    },
  };
  find.attach(pillOnly);
  find.showReplace("x");
  find.setReplacement("y");
  expect(find.getState().matches).toHaveLength(2);
  find.replaceAll();
  expect(editor.lines[0]).toBe("y y y y");
});

test("Replace moves past a replacement that contains the query", () => {
  const editor = fakeEditor(["foo foo"]);
  const find = new EditorFind();
  find.attach(editor.target);
  find.showReplace("foo");
  find.setReplacement("foo_bar");
  find.replace();
  expect(editor.lines[0]).toBe("foo_bar foo");
  // The active match is the untouched second "foo", not the text just written.
  expect(find.getState().active).toBe(1);
  find.replace();
  expect(editor.lines[0]).toBe("foo_bar foo_bar");
});

test("Replace All swaps every match in one undo step", () => {
  const editor = fakeEditor(["x1 x2", "x3"]);
  const find = new EditorFind();
  find.attach(editor.target);
  find.showReplace("x");
  find.setReplacement("y");
  find.replaceAll();
  expect(editor.lines).toEqual(["y1 y2", "y3"]);
  expect(editor.undoStops()).toBe(1);
  expect(find.getState().matches).toHaveLength(0);
});

test("a read-only file shows no replace row and replaces nothing", () => {
  const editor = fakeEditor(["keep"], true);
  const find = new EditorFind();
  find.attach(editor.target);
  find.showReplace("keep");
  expect(find.getState().replaceOpen).toBe(false);
  find.setReplacement("gone");
  find.replaceAll();
  expect(editor.lines).toEqual(["keep"]);
});
