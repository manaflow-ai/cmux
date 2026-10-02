import { describe, expect, test } from "bun:test";
import { applyDictation, type DictationAnchor, type DictationUpdate, type PromptState } from "./dictationText";

const update = (state: DictationUpdate["state"], text = "", extra: Partial<DictationUpdate> = {}): DictationUpdate => ({
  state,
  text,
  level: 0,
  cancelled: false,
  ...extra,
});
const caretAt = (value: string, caret = value.length): PromptState => ({
  value,
  selectionStart: caret,
  selectionEnd: caret,
});

/// Runs updates against a prompt the way the composer does, returning the prompt after each.
function run(
  start: PromptState,
  updates: DictationUpdate[],
  edit?: (index: number, prompt: PromptState) => PromptState,
) {
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
    const { seen, anchor } = run(caretAt(""), [
      update("starting"),
      update("listening"),
      update("listening", "fix the"),
      update("listening", "fix the bug"),
      update("finalizing", "fix the bug"),
      update("idle", "fix the bug"),
    ]);
    expect(seen.map((prompt) => prompt.value)).toEqual([
      "",
      "",
      "fix the",
      "fix the bug",
      "fix the bug",
      "fix the bug",
    ]);
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
    const { prompt } = run(caretAt("keep "), [
      update("listening", "drop this"),
      update("idle", "", { cancelled: true }),
    ]);
    expect(prompt.value).toBe("keep ");
    expect(prompt.selectionStart).toBe(5);
  });

  test("cancel leaves a caret the user moved away from the words", () => {
    const { prompt } = run(
      caretAt("abc def", 4),
      [update("listening", "hi"), update("idle", "", { cancelled: true })],
      (index, current) => (index === 1 ? { ...current, selectionStart: 0, selectionEnd: 0 } : current),
    );
    expect(prompt).toEqual({ value: "abc def", selectionStart: 0, selectionEnd: 0 });
  });

  test("a selection is replaced, and put back on cancel", () => {
    const selected: PromptState = { value: "fix the old bug", selectionStart: 8, selectionEnd: 11 };
    const replaced = run(selected, [update("starting"), update("listening", "new"), update("idle", "new")]);
    expect(replaced.prompt.value).toBe("fix the new bug");
    const restored = run(selected, [
      update("starting"),
      update("listening", "new"),
      update("idle", "", { cancelled: true }),
    ]);
    expect(restored.prompt.value).toBe("fix the old bug");
  });

  test("a session that ends with no words leaves the prompt as it was", () => {
    const selected: PromptState = { value: "fix the old bug", selectionStart: 8, selectionEnd: 11 };
    expect(run(selected, [update("starting"), update("denied", "", { permission: "microphone" })]).prompt.value).toBe(
      "fix the old bug",
    );
    expect(run(caretAt("draft"), [update("denied", "")]).prompt.value).toBe("draft");
  });

  test("a failure keeps what was heard", () => {
    expect(
      run(caretAt(""), [update("listening", "first part"), update("failed", "first part", { message: "x" })]).prompt
        .value,
    ).toBe("first part");
  });

  test("typing after the words while listening keeps the edit, the caret, and the revision", () => {
    const { prompt } = run(
      caretAt(""),
      [update("listening", "hello wor"), update("listening", "hello world"), update("idle", "hello world")],
      (index, current) => (index === 1 ? caretAt(current.value + "!") : current),
    );
    // The hypothesis "wor" still becomes "world"; the typed "!" and the caret after it stay.
    expect(prompt.value).toBe("hello world!");
    expect(prompt.selectionStart).toBe("hello world!".length);
  });

  test("typing before the words while listening moves them, without duplicates", () => {
    const { prompt } = run(
      caretAt(""),
      [update("listening", "fix it"), update("listening", "fix it now"), update("idle", "fix it now")],
      (index, current) =>
        index === 1 ? { value: "Please " + current.value, selectionStart: 7, selectionEnd: 7 } : current,
    );
    expect(prompt.value).toBe("Please fix it now");
    expect(prompt.selectionStart).toBe(7);
  });

  test("moving the cursor away keeps it there while words keep landing at the anchor", () => {
    const { prompt } = run(
      caretAt("intro. "),
      [update("listening", "one"), update("listening", "one two"), update("idle", "one two three")],
      (index, current) => (index === 1 ? { ...current, selectionStart: 2, selectionEnd: 2 } : current),
    );
    expect(prompt.value).toBe("intro. one two three");
    expect(prompt.selectionStart).toBe(2);
  });

  test("editing inside the words hands them over and continues where they ended", () => {
    const { prompt } = run(
      caretAt(""),
      [update("listening", "hello"), update("listening", "hello world"), update("idle", "hello world")],
      (index, current) => (index === 1 ? caretAt("Hello") : current),
    );
    expect(prompt.value).toBe("Hello world");
  });

  test("an edit while a word is still being spelled continues that word", () => {
    const { prompt } = run(
      caretAt(""),
      [update("listening", "hello wor"), update("listening", "hello world"), update("idle", "hello world")],
      (index, current) => (index === 1 ? { value: "Hello wor", selectionStart: 1, selectionEnd: 1 } : current),
    );
    expect(prompt.value).toBe("Hello world");
    // The caret stays where the user edited.
    expect(prompt.selectionStart).toBe(1);
  });

  test("a revision of words the user took over keeps theirs and adds only the new ones", () => {
    const { prompt } = run(
      caretAt(""),
      [
        update("listening", "I scream for"),
        update("listening", "ice cream for you"),
        update("idle", "ice cream for you"),
      ],
      (index, current) => (index === 1 ? { value: "We scream for", selectionStart: 2, selectionEnd: 2 } : current),
    );
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
    const { prompt } = run(
      caretAt(""),
      [update("starting"), update("listening", "hi"), update("idle", "hi")],
      (index, current) => (index === 1 ? caretAt("abc") : current),
    );
    expect(prompt.value).toBe("abc hi");
  });

  test("dictating in front of a word keeps the caret after the words, before the added space", () => {
    const { seen } = run(caretAt("Please now", 7), [
      update("listening", "fix"),
      update("listening", "fix it"),
      update("listening", "fix it please"),
    ]);
    expect(seen.map((prompt) => [prompt.value, prompt.selectionStart])).toEqual([
      ["Please fix now", 10],
      ["Please fix it now", 13],
      ["Please fix it please now", 20],
    ]);
  });

  test("a half-spelled word the user changed or deleted is not continued", () => {
    const edits = (value: string) => (index: number, current: PromptState) => (index === 1 ? caretAt(value) : current);
    const updates = [
      update("listening", "hello wor"),
      update("listening", "hello world"),
      update("listening", "hello world now"),
    ];
    expect(run(caretAt(""), updates, edits("hello ")).prompt.value).toBe("hello now");
    expect(run(caretAt(""), updates, edits("hello")).prompt.value).toBe("hello now");
    expect(run(caretAt(""), updates, edits("hello war")).prompt.value).toBe("hello war now");
  });

  test("cancel after the user took the words over leaves their text and caret", () => {
    const { prompt } = run(
      caretAt(""),
      [update("listening", "hello world"), update("idle", "", { cancelled: true })],
      (index, current) => (index === 1 ? { value: "hello World", selectionStart: 7, selectionEnd: 7 } : current),
    );
    expect(prompt).toEqual({ value: "hello World", selectionStart: 7, selectionEnd: 7 });
  });

  test("a revision of words the user took over never writes a word twice", () => {
    const edit = (value: string) => (index: number, current: PromptState) => (index === 1 ? caretAt(value) : current);
    const revise = (first: string, edited: string, next: string) =>
      run(caretAt(""), [update("listening", first), update("listening", next)], edit(edited)).prompt.value;
    expect(revise("I like it", "I love it", "I liked it")).toBe("I love it");
    expect(revise("hello world", "Hello world", "Hello world.")).toBe("Hello world");
    expect(revise("send the male", "Send the male", "send the mail")).toBe("Send the male");
    expect(revise("I want ice cream", "We want ice cream", "I want icecream please")).toBe("We want ice cream please");
    expect(revise("I like hel", "I love hel", "I liked hello")).toBe("I love hel");
    expect(revise("a b c", "A b c", "a b c")).toBe("A b c");
    // Respelled words: only what follows the last handed word is new.
    expect(revise("I'm going", "I'm Going", "I am going home")).toBe("I'm Going home");
    expect(revise("it's done", "It's done", "it is done now")).toBe("It's done now");
    expect(revise("gonna go", "Gonna go", "going to go home")).toBe("Gonna go home");
    expect(revise("I have 21", "We have 21", "I have twenty one dollars")).toBe("We have 21");
    expect(revise("I will", "I Will", "I'll go")).toBe("I Will");
    // The last handed word revised, with an earlier copy: nothing is added rather than repeated.
    expect(revise("the cat and the", "The cat and the", "The cat and then we left")).toBe("The cat and the");
    expect(revise("send it to me and to", "Send it to me and to", "Send it to me and two")).toBe(
      "Send it to me and to",
    );
    // Respelled with the last word repeated: unclear, so nothing rather than a repeat.
    expect(revise("I'm sure you're sure", "I'm sure you're Sure", "I am sure you are sure now")).toBe(
      "I'm sure you're Sure",
    );
    expect(revise("it's fine, it's fine", "It's fine, it's fine", "it is fine, it is fine okay")).toBe(
      "It's fine, it's fine",
    );
    // An expansion that adds an earlier copy of the last word: the last two words place it.
    expect(revise("I'm sure I", "I'm Sure I", "I am sure I will")).toBe("I'm Sure I will");
    expect(revise("you're right, you", "You're right, you", "you are right, you know")).toBe("You're right, you know");
    expect(revise("don't do", "Don't do", "do not do it")).toBe("Don't do");
    expect(revise("for the four", "For the four", "four the four people")).toBe("For the four people");
    expect(revise("hello world .", "Hi world .", "Hello world . more")).toBe("Hi world . more");
    // A repeated last pair whose final copy was revised: nothing rather than a repeat.
    expect(
      revise("talk to the team and to the", "Talk to the team and to the", "Talk to the team, and to them later"),
    ).toBe("Talk to the team and to the");
    expect(revise("what I mean is what I", "What I mean is what I", "What I mean is, what I'd")).toBe(
      "What I mean is what I",
    );
    expect(revise("I'm sure I", "I'm Sure I", "I am sure I'd like")).toBe("I'm Sure I");
    expect(revise("i'm going to the", "I'm going to the", "I am going to the store and then to the mall")).toBe(
      "I'm going to the",
    );
    // A longer revision adds the words past the handed ones.
    expect(revise("I scream for", "We scream for", "ice cream for you")).toBe("We scream for you");
  });

  test("a hand-over in a script without spaces keeps the characters that follow", () => {
    const edit = (value: string) => (index: number, current: PromptState) => (index === 1 ? caretAt(value) : current);
    expect(
      run(
        caretAt(""),
        [
          update("listening", "今天天气"),
          update("listening", "今天天气很好"),
          update("idle", "今天天气很好，我们去公园。"),
        ],
        edit("明天天气"),
      ).prompt.value,
    ).toBe("明天天气很好，我们去公园。");
    // The engine respells the handed characters: what follows their last one is new.
    expect(
      run(caretAt(""), [update("listening", "今天天气"), update("listening", "今天的天气很好")], edit("明天天气"))
        .prompt.value,
    ).toBe("明天天气很好");
    expect(
      run(caretAt(""), [update("listening", "今天天气"), update("listening", "今天气很好")], edit("明天天气")).prompt
        .value,
    ).toBe("明天天气很好");
    expect(
      run(caretAt(""), [update("listening", "天气很好天"), update("listening", "天气真好")], edit("天气不好天")).prompt
        .value,
    ).toBe("天气不好天");
    // Common corrections (他/她, 的/得) place the new characters after the last two.
    expect(
      run(caretAt(""), [update("listening", "他说她"), update("listening", "她说她很好")], edit("他說她")).prompt.value,
    ).toBe("他說她很好");
    expect(
      run(caretAt(""), [update("listening", "跑得快的"), update("listening", "跑的快的人")], edit("跑得很快的")).prompt
        .value,
    ).toBe("跑得很快的人");
    expect(
      run(
        caretAt(""),
        [update("listening", "打开Chrome"), update("listening", "打开Google Chrome浏览器")],
        edit("打開Chrome"),
      ).prompt.value,
    ).toBe("打開Chrome浏览器");
    expect(
      run(
        caretAt(""),
        [update("listening", "他的书和他的"), update("listening", "他的书和她的笔")],
        edit("他的書和他的"),
      ).prompt.value,
    ).toBe("他的書和他的");
    // Characters outside the Basic Multilingual Plane count as one.
    expect(
      run(caretAt(""), [update("listening", "𠮷野"), update("listening", "𠮷の野家")], edit("吉野")).prompt.value,
    ).toBe("吉野家");
    expect(
      run(caretAt(""), [update("listening", "こんにちは"), update("listening", "こんにちは世界")], edit("こんばんは"))
        .prompt.value,
    ).toBe("こんばんは世界");
  });

  test("a revision of spaced words that adds another script is split by words", () => {
    const { prompt } = run(
      caretAt(""),
      [update("listening", "hi there"), update("listening", "Hi, there 世界")],
      (index, current) => (index === 1 ? caretAt("Hi there") : current),
    );
    expect(prompt.value).toBe("Hi there 世界");
  });

  test("the final text replaces the partial without duplicates or lost words", () => {
    const { seen } = run(caretAt("Note: "), [
      update("listening", "the quick"),
      update("listening", "the quick brown"),
      update("listening", "the quick brown fox jumps"),
      update("finalizing", "The quick brown fox jumps."),
      update("idle", "The quick brown fox jumps."),
    ]);
    expect(seen.map((prompt) => prompt.value)).toEqual([
      "Note: the quick",
      "Note: the quick brown",
      "Note: the quick brown fox jumps",
      "Note: The quick brown fox jumps.",
      "Note: The quick brown fox jumps.",
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
