// The code editor's find drives the shared find pill instead of Monaco's widget (Lawrence,
// 2026-10-20). EditorFind over a fake editor: matches from the caret, wrapping steps, match case,
// Cmd-G opening a closed pill, and Escape clearing highlights and returning the keyboard.
import { expect, test } from "bun:test";
import { EditorFind, type FindRange, type FindTarget } from "./editorFind";

function fakeEditor(lines: string[], caret = { lineNumber: 1, column: 1 }, selection = "") {
  const shown: { matches: readonly FindRange[]; active: number }[] = [];
  let focused = 0;
  const target: FindTarget = {
    findMatches(query, matchCase) {
      const out: FindRange[] = [];
      lines.forEach((line, i) => {
        const hay = matchCase ? line : line.toLowerCase();
        const needle = matchCase ? query : query.toLowerCase();
        for (let at = hay.indexOf(needle); at >= 0; at = hay.indexOf(needle, at + 1)) {
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
    caret: () => caret,
    selectedText: () => selection,
    show: (matches, active) => void shown.push({ matches, active }),
    focus: () => void focused++,
  };
  return { target, shown, focused: () => focused };
}

test("Cmd-F opens the pill, focuses its field, and finds from the caret", () => {
  const editor = fakeEditor(["error one", "fine", "Error two", "error three"], { lineNumber: 2, column: 1 });
  const find = new EditorFind();
  find.attach(editor.target);
  find.show();
  expect(find.getState().open).toBe(true);
  expect(find.getState().focusRequest).toBe(1);
  find.setQuery("error");
  expect(find.getState().matches).toHaveLength(3);
  // The first match at or after the caret (line 3), not the first in the file.
  expect(find.getState().active).toBe(1);
  expect(editor.shown.at(-1)?.active).toBe(1);
});

test("next and previous wrap around", () => {
  const editor = fakeEditor(["a", "a", "a"]);
  const find = new EditorFind();
  find.attach(editor.target);
  find.show("a");
  expect(find.getState().active).toBe(0);
  find.previous();
  expect(find.getState().active).toBe(2);
  find.next();
  expect(find.getState().active).toBe(0);
});

test("match case narrows the matches", () => {
  const editor = fakeEditor(["Error error ERROR"]);
  const find = new EditorFind();
  find.attach(editor.target);
  find.show("error");
  expect(find.getState().matches).toHaveLength(3);
  find.setMatchCase(true);
  expect(find.getState().matches).toHaveLength(1);
});

test("Find Next with the pill closed opens it with the last query", () => {
  const editor = fakeEditor(["needle", "needle"]);
  const find = new EditorFind();
  find.attach(editor.target);
  find.show("needle");
  find.hide();
  find.next();
  expect(find.getState().open).toBe(true);
  expect(find.getState().query).toBe("needle");
  expect(find.getState().matches).toHaveLength(2);
});

test("Escape clears the highlights and gives the keyboard back to the editor", () => {
  const editor = fakeEditor(["x x"]);
  const find = new EditorFind();
  find.attach(editor.target);
  find.show("x");
  find.hide();
  expect(find.getState().open).toBe(false);
  expect(editor.shown.at(-1)?.matches).toHaveLength(0);
  expect(editor.focused()).toBe(1);
  // The query stays for the next Cmd-F.
  expect(find.getState().query).toBe("x");
});

test("Use Selection for Find searches the selected text", () => {
  const editor = fakeEditor(["foo bar foo"], { lineNumber: 1, column: 1 }, "foo");
  const find = new EditorFind();
  find.attach(editor.target);
  find.useSelection();
  expect(find.getState().query).toBe("foo");
  expect(find.getState().matches).toHaveLength(2);
});

test("an edit searches again and keeps the active match's place", () => {
  const lines = ["k", "k", "k"];
  const editor = fakeEditor(lines);
  const find = new EditorFind();
  find.attach(editor.target);
  find.show("k");
  find.next();
  lines.pop();
  find.refresh();
  expect(find.getState().matches).toHaveLength(2);
  expect(find.getState().active).toBe(1);
});

test("typing the query a letter at a time stays on the first match (search starts at the selection)", () => {
  // Selecting a match moves the editor's caret to its end, as Monaco does; the search starts from
  // the selection's start, so each new letter keeps the match it is on.
  const lines = ["alpha beta", "alpha gamma", "Alpha delta"];
  let selection = { start: { lineNumber: 1, column: 1 }, end: { lineNumber: 1, column: 1 } };
  const find = new EditorFind();
  find.attach({
    findMatches(query) {
      const out: FindRange[] = [];
      lines.forEach((line, i) => {
        for (let at = line.toLowerCase().indexOf(query); at >= 0; at = line.toLowerCase().indexOf(query, at + 1))
          out.push({
            startLineNumber: i + 1,
            startColumn: at + 1,
            endLineNumber: i + 1,
            endColumn: at + 1 + query.length,
          });
      });
      return out;
    },
    caret: () => selection.start,
    selectedText: () => "",
    show(matches, active) {
      const range = matches[active];
      if (range)
        selection = {
          start: { lineNumber: range.startLineNumber, column: range.startColumn },
          end: { lineNumber: range.endLineNumber, column: range.endColumn },
        };
    },
    focus: () => undefined,
  });
  find.show();
  for (const query of ["a", "al", "alp", "alph", "alpha"]) find.setQuery(query);
  expect(find.getState().matches).toHaveLength(3);
  expect(find.getState().active).toBe(0);
});
