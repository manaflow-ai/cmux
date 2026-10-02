import { describe, expect, test } from "bun:test";
import { applyDictation, type DictationAnchor, type DictationUpdate, type PromptState } from "./dictationText";

const update = (state: DictationUpdate["state"], text = "", extra: Partial<DictationUpdate> = {}): DictationUpdate => ({ state, text, level: 0, cancelled: false, ...extra });
const caretAt = (value: string, caret = value.length): PromptState => ({ value, selectionStart: caret, selectionEnd: caret });

/// Runs updates against a prompt the way the composer does, returning the prompt after each.
function run(start: PromptState, updates: DictationUpdate[], edit?: (index: number, prompt: PromptState) => PromptState) {
  let prompt = start;
  let anchor: DictationAnchor | null = null;
  const seen: PromptState[] = [];
  updates.forEach((next, index) => {
    if (edit) prompt = edit(index, prompt);
    const splice = applyDictation(prompt, anchor, next);
    if (splice) {
      anchor = splice.anchor;
      prompt = { value: splice.value, selectionStart: splice.selectionStart, selectionEnd: splice.selectionEnd };
    }
    seen.push(prompt);
  });
  return { prompt, seen, anchor: anchor as DictationAnchor | null };
}

describe("dictation text", () => {
  test("streams into an empty prompt and keeps the words on stop", () => {
    const { seen, anchor } = run(caretAt(""), [update("starting"), update("listening"), update("listening", "fix the"), update("listening", "fix the bug"), update("finalizing", "fix the bug"), update("idle", "fix the bug")]);
    expect(seen.map((prompt) => prompt.value)).toEqual(["", "", "fix the", "fix the bug", "fix the bug", "fix the bug"]);
    expect(seen.at(-1)?.selectionStart).toBe("fix the bug".length);
    expect(anchor).toBeNull();
  });

  test("a revised hypothesis replaces the earlier one in place", () => {
    const { prompt } = run(caretAt(""), [update("listening", "their"), update("listening", "there it is")]);
    expect(prompt.value).toBe("there it is");
  });

  test("inserts at the cursor and keeps the typed text around it", () => {
    const { prompt } = run(caretAt("Please  now", 7), [update("listening", "fix it"), update("idle", "fix it")]);
    expect(prompt.value).toBe("Please fix it now");
    expect(prompt.selectionStart).toBe("Please fix it".length);
  });

  test("adds a space after a word and before the next one", () => {
    expect(run(caretAt("fix"), [update("listening", "the bug")]).prompt.value).toBe("fix the bug");
    expect(run(caretAt("fix bug", 3), [update("listening", "the")]).prompt.value).toBe("fix the bug");
    expect(run(caretAt("hello "), [update("listening", "world")]).prompt.value).toBe("hello world");
  });

  test("punctuation attaches without a space", () => {
    expect(run(caretAt("done"), [update("listening", ", thanks")]).prompt.value).toBe("done, thanks");
  });

  test("cancel removes the session's words and keeps the user's", () => {
    const { prompt } = run(caretAt("keep "), [update("listening", "drop this"), update("idle", "", { cancelled: true })]);
    expect(prompt.value).toBe("keep ");
    expect(prompt.selectionStart).toBe(5);
  });

  test("a selection is replaced, and put back on cancel", () => {
    const selected: PromptState = { value: "fix the old bug", selectionStart: 8, selectionEnd: 11 };
    const replaced = run(selected, [update("starting"), update("listening", "new"), update("idle", "new")]);
    expect(replaced.prompt.value).toBe("fix the new bug");
    const restored = run(selected, [update("starting"), update("listening", "new"), update("idle", "", { cancelled: true })]);
    expect(restored.prompt.value).toBe("fix the old bug");
  });

  test("a session that ends with no words leaves the prompt as it was", () => {
    const selected: PromptState = { value: "fix the old bug", selectionStart: 8, selectionEnd: 11 };
    expect(run(selected, [update("starting"), update("denied", "", { permission: "microphone" })]).prompt.value).toBe("fix the old bug");
    expect(run(caretAt("draft"), [update("denied", "")]).prompt.value).toBe("draft");
  });

  test("a failure keeps what was heard", () => {
    expect(run(caretAt(""), [update("listening", "first part"), update("failed", "first part", { message: "x" })]).prompt.value).toBe("first part");
  });

  test("typing after the words while listening keeps the edit, the caret, and the revision", () => {
    const { prompt } = run(caretAt(""), [update("listening", "hello wor"), update("listening", "hello world"), update("idle", "hello world")], (index, current) =>
      index === 1 ? caretAt(current.value + "!") : current);
    // The hypothesis "wor" still becomes "world"; the typed "!" and the caret after it stay.
    expect(prompt.value).toBe("hello world!");
    expect(prompt.selectionStart).toBe("hello world!".length);
  });

  test("typing before the words while listening moves them, without duplicates", () => {
    const { prompt } = run(caretAt(""), [update("listening", "fix it"), update("listening", "fix it now"), update("idle", "fix it now")], (index, current) =>
      index === 1 ? { value: "Please " + current.value, selectionStart: 7, selectionEnd: 7 } : current);
    expect(prompt.value).toBe("Please fix it now");
    expect(prompt.selectionStart).toBe(7);
  });

  test("moving the cursor away keeps it there while words keep landing at the anchor", () => {
    const { prompt } = run(caretAt("intro. "), [update("listening", "one"), update("listening", "one two"), update("idle", "one two three")], (index, current) =>
      index === 1 ? { ...current, selectionStart: 2, selectionEnd: 2 } : current);
    expect(prompt.value).toBe("intro. one two three");
    expect(prompt.selectionStart).toBe(2);
  });

  test("editing inside the words hands them over and continues where they ended", () => {
    const { prompt } = run(caretAt(""), [update("listening", "hello"), update("listening", "hello world"), update("idle", "hello world")], (index, current) =>
      index === 1 ? caretAt("Hello") : current);
    expect(prompt.value).toBe("Hello world");
  });

  test("an edit while a word is still being spelled continues that word", () => {
    const { prompt } = run(caretAt(""), [update("listening", "hello wor"), update("listening", "hello world"), update("idle", "hello world")], (index, current) =>
      index === 1 ? { value: "Hello wor", selectionStart: 1, selectionEnd: 1 } : current);
    expect(prompt.value).toBe("Hello world");
    // The caret stays where the user edited.
    expect(prompt.selectionStart).toBe(1);
  });

  test("a revision of words the user took over keeps theirs and adds only the new ones", () => {
    const { prompt } = run(caretAt(""), [update("listening", "I scream for"), update("listening", "ice cream for you"), update("idle", "ice cream for you")], (index, current) =>
      index === 1 ? { value: "We scream for", selectionStart: 2, selectionEnd: 2 } : current);
    expect(prompt.value).toBe("We scream for you");
  });

  test("a session that ends with nothing new after a send leaves the new draft and caret alone", () => {
    const start = caretAt("");
    let anchor: DictationAnchor | null = applyDictation(start, null, update("listening", "first message"))!.anchor;
    // Send cleared the prompt; the user starts typing the next message.
    const typing = caretAt("typing new");
    const end = applyDictation(typing, anchor, update("idle", "first message"));
    anchor = end?.anchor ?? null;
    expect(end).toMatchObject({ value: "typing new", selectionStart: 10, selectionEnd: 10, placed: false });
    expect(anchor).toBeNull();
  });

  test("typing before any words arrive puts the words after the typing", () => {
    const { prompt } = run(caretAt(""), [update("starting"), update("listening", "hi"), update("idle", "hi")], (index, current) =>
      index === 1 ? caretAt("abc") : current);
    expect(prompt.value).toBe("abc hi");
  });

  test("the final text replaces the partial without duplicates or lost words", () => {
    const { seen } = run(caretAt("Note: "), [
      update("listening", "the quick"), update("listening", "the quick brown"), update("listening", "the quick brown fox jumps"),
      update("finalizing", "The quick brown fox jumps."), update("idle", "The quick brown fox jumps."),
    ]);
    expect(seen.map((prompt) => prompt.value)).toEqual([
      "Note: the quick", "Note: the quick brown", "Note: the quick brown fox jumps", "Note: The quick brown fox jumps.", "Note: The quick brown fox jumps.",
    ]);
  });

  test("CJK and paths get no stray spaces", () => {
    expect(run(caretAt("我想"), [update("listening", "修复这个")]).prompt.value).toBe("我想修复这个");
    expect(run(caretAt("これは"), [update("listening", "テストです")]).prompt.value).toBe("これはテストです");
    expect(run(caretAt("错误", 0), [update("listening", "修复")]).prompt.value).toBe("修复错误");
    expect(run(caretAt("open src/"), [update("listening", "main")]).prompt.value).toBe("open src/main");
    expect(run(caretAt("call ("), [update("listening", "foo")]).prompt.value).toBe("call (foo");
  });

  test("updates before a session starts change nothing", () => {
    expect(applyDictation(caretAt("draft"), null, update("idle", "", { cancelled: true }))).toBeNull();
    expect(applyDictation(caretAt("draft"), null, update("idle", "late"))).toBeNull();
  });
});
