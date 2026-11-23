import { describe, expect, test } from "bun:test";
import { VIM_START, vimKey, type VimState, type VimStep } from "../src/agent-session/acpmux/composer/composerVim";

// `|` marks the caret in these prompts.
function parse(marked: string) {
  const caret = marked.indexOf("|");
  return { value: marked.replace("|", ""), caret };
}
function mark(value: string, caret: number) {
  return `${value.slice(0, caret)}|${value.slice(caret)}`;
}
const NORMAL: VimState = { ...VIM_START, mode: "normal" };

/// Types `keys` (one character each; `<Esc>` is Esc) from `state` over `marked`, applying each step
/// as the composer does. Returns the prompt, the last state and every step.
function run(marked: string, keys: string, state: VimState = NORMAL) {
  let { value, caret } = parse(marked);
  let current = state;
  const steps: VimStep[] = [];
  const list = keys.split(/(<Esc>)/).flatMap((part) => (part === "<Esc>" ? ["Escape"] : part.split("")));
  for (const key of list) {
    const step = vimKey(current, { key }, { value, caret });
    steps.push(step);
    current = step.state;
    if (step.text) ({ value, caret } = step.text);
  }
  return { text: mark(value, caret), state: current, steps };
}

describe("modes", () => {
  test("Esc enters Normal mode with the caret on the character before it", () => {
    const { text, state, steps } = run("hello|", "<Esc>", VIM_START);
    expect(state.mode).toBe("normal");
    expect(steps[0]?.handled).toBe(true);
    expect(text).toBe("hell|o");
  });
  test("Insert mode leaves every other key to the composer, Enter included", () => {
    for (const key of ["a", "Enter", "j", "Backspace"]) {
      expect(vimKey(VIM_START, { key }, { value: "x", caret: 1 }).handled).toBe(false);
    }
  });
  test("i a A I o enter Insert mode at vim's place", () => {
    expect(run("  ab|c", "i").text).toBe("  ab|c");
    expect(run("  ab|c", "a").text).toBe("  abc|");
    expect(run("  a|bc\nz", "A").text).toBe("  abc|\nz");
    expect(run("  ab|c", "I").text).toBe("  |abc");
    expect(run("a|b\nz", "o").text).toBe("ab\n|\nz");
    for (const key of ["i", "a", "A", "I", "o"]) expect(run("ab|c", key).state.mode).toBe("insert");
  });
  test("Normal mode leaves Enter, Esc, Tab, arrows and shortcuts to the composer", () => {
    for (const key of [
      { key: "Enter" },
      { key: "Escape" },
      { key: "Tab" },
      { key: "ArrowUp" },
      { key: "c", meta: true },
      { key: "a", ctrl: true },
    ]) {
      expect(vimKey(NORMAL, key, { value: "abc", caret: 1 }).handled).toBe(false);
    }
  });
  test("Normal mode takes a key it does not know, so nothing types", () => {
    const step = vimKey(NORMAL, { key: "Q" }, { value: "abc", caret: 1 });
    expect(step.handled).toBe(true);
    expect(step.text).toBeUndefined();
  });
});

describe("motions", () => {
  test("h and l stay on the line", () => {
    expect(run("ab\n|cd", "h").text).toBe("ab\n|cd");
    expect(run("ab\nc|d", "l").text).toBe("ab\nc|d");
    expect(run("a|bc", "l").text).toBe("ab|c");
    expect(run("ab|c", "h").text).toBe("a|bc");
  });
  test("j and k keep the column, clamped to the shorter line", () => {
    expect(run("abc|d\nef\nghij", "j").text).toBe("abcd\ne|f\nghij");
    expect(run("abcd\ne|f\nghij", "j").text).toBe("abcd\nef\ng|hij");
    expect(run("abcd\nef\ngh|ij", "k").text).toBe("abcd\ne|f\nghij");
    expect(run("ab|c", "k").text).toBe("ab|c");
  });
  test("w b e move by words, punctuation its own word", () => {
    expect(run("|foo bar.baz", "w").text).toBe("foo |bar.baz");
    expect(run("|foo bar.baz", "ww").text).toBe("foo bar|.baz");
    expect(run("foo bar|.baz", "b").text).toBe("foo |bar.baz");
    expect(run("|foo bar", "e").text).toBe("fo|o bar");
    expect(run("fo|o bar", "e").text).toBe("foo ba|r");
    expect(run("|one\ntwo", "w").text).toBe("one\n|two");
  });
  test("0 $ gg G go to the line's and the prompt's ends", () => {
    expect(run("ab\nc|de\nf", "0").text).toBe("ab\n|cde\nf");
    expect(run("ab\n|cde\nf", "$").text).toBe("ab\ncd|e\nf");
    expect(run("ab\nc|de\nf", "gg").text).toBe("|ab\ncde\nf");
    expect(run("a|b\ncde\nfg", "G").text).toBe("ab\ncde\n|fg");
  });
});

describe("edits", () => {
  test("x deletes the character under the caret", () => {
    expect(run("a|bc", "x").text).toBe("a|c");
    expect(run("ab|c", "x").text).toBe("a|b");
  });
  test("dd deletes the line, the last one too", () => {
    expect(run("one\nt|wo\nthree", "dd").text).toBe("one\n|three");
    expect(run("one\nt|wo", "dd").text).toBe("|one");
    expect(run("o|nly", "dd").text).toBe("|");
  });
  test("dw deletes to the next word, and stops at the line's end", () => {
    expect(run("|foo bar", "dw").text).toBe("|bar");
    expect(run("foo |bar\nbaz", "dw").text).toBe("foo| \nbaz");
  });
  test("cw changes to the word's end and enters Insert mode", () => {
    const { text, state } = run("|foo bar", "cw");
    expect(text).toBe("| bar");
    expect(state.mode).toBe("insert");
  });
  test("D deletes to the line's end; C does and enters Insert mode", () => {
    expect(run("ab|cd\nef", "D").text).toBe("a|b\nef");
    const changed = run("ab|cd\nef", "C");
    expect(changed.text).toBe("ab|\nef");
    expect(changed.state.mode).toBe("insert");
  });
  test("u asks the prompt to undo", () => {
    const step = vimKey(NORMAL, { key: "u" }, { value: "abc", caret: 1 });
    expect(step.handled).toBe(true);
    expect(step.undo).toBe(true);
  });
  test("yy then p puts the line below; x then p puts the character after the caret", () => {
    expect(run("o|ne\ntwo", "yyp").text).toBe("one\n|one\ntwo");
    expect(run("one\nt|wo", "yyjp").text).toBe("one\ntwo\n|two");
    expect(run("|abc", "xp").text).toBe("b|ac");
  });
  test("dd then p moves a line down", () => {
    expect(run("o|ne\ntwo", "ddp").text).toBe("two\n|one");
  });
  test("an operator with a key that is no motion is dropped", () => {
    const { text, state } = run("a|bc", "dq");
    expect(text).toBe("a|bc");
    expect(state.pending).toBeUndefined();
  });
  test("a full round: type, Esc, b, cw, type again", () => {
    let state = VIM_START;
    let value = "hello world";
    let caret = value.length;
    const press = (key: string) => {
      const step = vimKey(state, { key }, { value, caret });
      state = step.state;
      if (step.text) ({ value, caret } = step.text);
      if (!step.handled && key.length === 1) {
        value = value.slice(0, caret) + key + value.slice(caret);
        caret += 1;
      }
    };
    for (const key of ["Escape", "b", "c", "w", "t", "h", "e", "r", "e"]) press(key);
    expect(state.mode).toBe("insert");
    expect(mark(value, caret)).toBe("hello there|");
  });
});
