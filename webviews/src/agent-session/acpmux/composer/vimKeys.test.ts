import { expect, test } from "bun:test";
import { handleVimKey, VIM_INITIAL, type VimState, wordBack, wordEnd, wordForward } from "./vimKeys";

const normal: VimState = { mode: "normal", pending: "" };

/// Runs `keys` from `state` over `text` with the caret at `caret`; returns where it ends.
function run(text: string, caret: number, keys: string[], state: VimState = normal) {
  let undone = 0;
  for (const key of keys) {
    const result = handleVimKey(state, { key }, text, caret);
    state = result.state;
    if (result.value !== undefined) text = result.value;
    if (result.caret !== undefined) caret = result.caret;
    if (result.undo) undone += 1;
  }
  return { text, caret, state, undone };
}

test("a prompt starts in insert mode and types everything but Esc", () => {
  for (const key of ["a", "j", "Enter", "d", "Tab", "ArrowLeft"]) {
    expect(handleVimKey(VIM_INITIAL, { key }, "hello", 5).handled).toBe(false);
  }
  expect(handleVimKey(VIM_INITIAL, { key: "Escape", metaKey: true }, "hello", 5).handled).toBe(false);
});

test("Esc leaves insert for normal and steps the caret back onto a character", () => {
  const result = handleVimKey(VIM_INITIAL, { key: "Escape" }, "hello", 5);
  expect(result).toMatchObject({ handled: true, caret: 4, state: { mode: "normal" } });
  expect(handleVimKey(VIM_INITIAL, { key: "Escape" }, "a\nbc", 2).caret).toBe(2);
});

test("Esc in normal mode is the composer's, except to end a pending d", () => {
  expect(handleVimKey(normal, { key: "Escape" }, "x", 0).handled).toBe(false);
  const pending = run("one", 0, ["d"]);
  expect(pending.state.pending).toBe("d");
  const result = handleVimKey(pending.state, { key: "Escape" }, "one", 0);
  expect(result).toMatchObject({ handled: true, state: { mode: "normal", pending: "" } });
});

test("normal mode takes plain keys so none types, and leaves chords and named keys alone", () => {
  expect(handleVimKey(normal, { key: "z" }, "abc", 1)).toMatchObject({ handled: true, caret: 1 });
  expect(handleVimKey(normal, { key: "Q" }, "abc", 1).value).toBeUndefined();
  for (const event of [
    { key: "Enter" },
    { key: "Tab" },
    { key: "ArrowUp" },
    { key: "Backspace" },
    { key: "c", metaKey: true },
    { key: "r", ctrlKey: true },
    { key: "j", altKey: true },
  ]) {
    expect(handleVimKey(normal, event, "abc", 1).handled).toBe(false);
  }
});

test("i, a, I, A and o enter insert mode where vim puts the caret", () => {
  expect(run("  hello", 4, ["i"])).toMatchObject({ caret: 4, state: { mode: "insert" } });
  expect(run("  hello", 4, ["a"])).toMatchObject({ caret: 5, state: { mode: "insert" } });
  expect(run("  hello", 4, ["I"])).toMatchObject({ caret: 2, state: { mode: "insert" } });
  expect(run("  hello", 4, ["A"])).toMatchObject({ caret: 7, state: { mode: "insert" } });
  expect(run("one\ntwo", 1, ["o"])).toMatchObject({ text: "one\n\ntwo", caret: 4, state: { mode: "insert" } });
  expect(run("", 0, ["a"])).toMatchObject({ caret: 0, state: { mode: "insert" } });
});

test("h and l stay on their line; l stops on the last character", () => {
  expect(run("ab\ncd", 3, ["h"]).caret).toBe(3);
  expect(run("ab\ncd", 1, ["l"]).caret).toBe(1);
  expect(run("abc", 0, ["l", "l", "l"]).caret).toBe(2);
  expect(run("abc", 2, ["h"]).caret).toBe(1);
});

test("j and k keep the column and clamp to a shorter line", () => {
  expect(run("abcd\nef\nghij", 3, ["j"]).caret).toBe(6);
  expect(run("abcd\nef\nghij", 6, ["j"]).caret).toBe(9);
  expect(run("abcd\nef\nghij", 10, ["k"]).caret).toBe(6);
  expect(run("abcd\nef\nghij", 10, ["k", "k"]).caret).toBe(1);
  expect(run("one", 1, ["j"]).caret).toBe(1);
  expect(run("one", 1, ["k"]).caret).toBe(1);
});

test("0 and $ go to the ends of the line", () => {
  expect(run("ab\ncdef", 5, ["0"]).caret).toBe(3);
  expect(run("ab\ncdef", 3, ["$"]).caret).toBe(6);
  expect(run("ab\n\ncd", 3, ["$"]).caret).toBe(3);
});

test("w, b and e move by word, punctuation and space", () => {
  const text = "foo bar.baz  qux";
  expect(wordForward(text, 0)).toBe(4);
  expect(wordForward(text, 4)).toBe(7);
  expect(wordForward(text, 7)).toBe(8);
  expect(wordForward(text, 8)).toBe(13);
  expect(wordForward(text, 13)).toBe(text.length - 1);
  expect(wordBack(text, 13)).toBe(8);
  expect(wordBack(text, 8)).toBe(7);
  expect(wordBack(text, 4)).toBe(0);
  expect(wordBack(text, 0)).toBe(0);
  expect(wordEnd(text, 0)).toBe(2);
  expect(wordEnd(text, 2)).toBe(6);
  expect(wordEnd(text, 6)).toBe(7);
  expect(wordEnd(text, 15)).toBe(15);
  expect(run("a\nb", 0, ["w"]).caret).toBe(2);
});

test("x deletes the character under the caret and keeps the caret on the line", () => {
  expect(run("abc", 1, ["x"])).toMatchObject({ text: "ac", caret: 1 });
  expect(run("abc", 2, ["x"])).toMatchObject({ text: "ab", caret: 1 });
  expect(run("a\nb", 1, ["x"]).text).toBe("a\nb");
  expect(run("", 0, ["x"]).text).toBe("");
});

test("dd deletes the line, the first, a middle and the last", () => {
  expect(run("one\ntwo\nthree", 1, ["d", "d"])).toMatchObject({ text: "two\nthree", caret: 0 });
  expect(run("one\n  two\nthree", 5, ["d", "d"])).toMatchObject({ text: "one\nthree", caret: 4 });
  expect(run("one\ntwo\n  three", 9, ["d", "d"])).toMatchObject({ text: "one\ntwo", caret: 4 });
  expect(run("only", 2, ["d", "d"])).toMatchObject({ text: "", caret: 0 });
  expect(run("one\ntwo", 1, ["d", "x"])).toMatchObject({ text: "one\ntwo", state: { pending: "" } });
});

test("u asks for the field's undo and nothing else", () => {
  expect(run("abc", 1, ["u"])).toMatchObject({ undone: 1, text: "abc" });
});

test("a full round: Esc, dd, o, then type again", () => {
  let r = run("first\nsecond", 8, ["d", "d", "o"]);
  expect(r.text).toBe("first\n");
  expect(r.state.mode).toBe("insert");
  expect(handleVimKey(r.state, { key: "Enter" }, r.text, r.caret).handled).toBe(false);
});
