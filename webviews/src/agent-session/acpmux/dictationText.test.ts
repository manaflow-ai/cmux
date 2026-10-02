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
      prompt = { value: splice.value, selectionStart: splice.caret, selectionEnd: splice.caret };
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

  test("typing mid-session keeps the edit and continues at the caret", () => {
    const { prompt } = run(caretAt(""), [update("listening", "hello"), update("listening", "hello world"), update("idle", "hello world")], (index, current) => {
      // Before the second update the user types "!" after the dictated word.
      if (index !== 1) return current;
      return caretAt(current.value + "!");
    });
    expect(prompt.value).toBe("hello! world");
  });

  test("updates before a session starts change nothing", () => {
    expect(applyDictation(caretAt("draft"), null, update("idle", "", { cancelled: true }))).toBeNull();
    expect(applyDictation(caretAt("draft"), null, update("idle", "late"))).toBeNull();
  });
});
