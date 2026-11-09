import { afterEach, describe, expect, test } from "bun:test";
import {
  deletePrompt,
  fillPrompt,
  promptSlug,
  promptsFrom,
  refreshSavedPrompts,
  savePrompt,
  savedPromptCommands,
  seedSavedPrompts,
  setSavedPromptsTransport,
  suggestedName,
  savedPromptsNow,
  withPrompt,
  wordEnd,
  type SavedPrompt,
} from "./savedPrompts";
import { returnPicks, slashMatches } from "./slashCommands";

afterEach(() => {
  setSavedPromptsTransport(undefined);
  seedSavedPrompts([]);
});

describe("saved prompts", () => {
  test("a name types as a lower-case slug", () => {
    expect(promptSlug("Review PR")).toBe("review-pr");
    expect(promptSlug("  Daily standup!! ")).toBe("daily-standup");
    expect(promptSlug("v1.2 notes_draft")).toBe("v1.2-notes_draft");
    expect(promptSlug("日本語 メモ")).toBe("日本語-メモ");
    expect(promptSlug("!!!")).toBe("");
  });

  test("the menu rows carry the text, and a slug two names share goes to the first", () => {
    const rows = savedPromptCommands([
      { name: "Review PR", text: "Review this PR\nthoroughly", source: "saved" },
      { name: "review pr", text: "other", source: "settings" },
      { name: "!!!", text: "no slug", source: "saved" },
    ]);
    expect(rows).toEqual([
      { name: "review-pr", description: "Review this PR", source: "saved", body: "Review this PR\nthoroughly" },
    ]);
  });

  test("a saved prompt is offered mid-prompt too, and Return picks it typed in full", () => {
    const rows = savedPromptCommands([{ name: "standup", text: "What did I do", source: "saved" }]);
    const mid = slashMatches(rows, { query: "stand", length: 6, leading: false });
    expect(mid.map((match) => match.command.name)).toEqual(["standup"]);
    expect(returnPicks(mid[0], "standup", false)).toBe(true);
  });

  test("variables the chat knows are filled; the first other one is left selected", () => {
    const now = new Date(2026, 10, 8, 9, 5);
    const filled = fillPrompt("On {{branch}} in {{ folder }} ({{date}} {{time}}): fix {{issue}} then {{other}}", {
      cwd: "/Users/me/src/cmux/",
      branch: "feat-x",
      now,
    });
    expect(filled.text).toBe("On feat-x in cmux (2026-11-08 09:05): fix {{issue}} then {{other}}");
    expect(filled.text.slice(...filled.open!)).toBe("{{issue}}");
  });

  test("a variable the chat cannot fill stays, and a prompt with none has no selection", () => {
    expect(fillPrompt("on {{branch}}", {}).text).toBe("on {{branch}}");
    // Only its own variables: `{{constructor}}` stays open, as any name it does not know.
    expect(fillPrompt("{{constructor}} and {{toString}}", {})).toEqual({
      text: "{{constructor}} and {{toString}}",
      open: [0, 15],
    });
    expect(fillPrompt("on {{branch}}", {}).open).toEqual([3, 13]);
    expect(fillPrompt("plain {not a var}", {})).toEqual({ text: "plain {not a var}" });
  });

  test("a suggested name is the first words, without a leading command or Markdown", () => {
    expect(suggestedName("/review **Check** the `diff` for regressions please now\nmore")).toBe(
      "Check the diff for regressions",
    );
    expect(suggestedName("x".repeat(200)).length).toBe(64);
  });

  test("acpmux's rows are read, malformed ones left out", () => {
    expect(
      promptsFrom({
        prompts: [
          { name: " a ", text: "t", source: "settings", updatedAt: null },
          { name: "b", text: "u", updatedAt: 5 },
          { name: "", text: "x" },
          { name: "c", text: "  " },
          "junk",
        ],
      }),
    ).toEqual([
      { name: "a", text: "t", source: "settings" },
      { name: "b", text: "u", source: "saved", updatedAt: 5 },
    ]);
  });

  test("a save replaces a prompt of the same name in any case and keeps the list by name", () => {
    const list: SavedPrompt[] = [
      { name: "beta", text: "1", source: "saved" },
      { name: "Alpha", text: "2", source: "settings" },
    ];
    expect(withPrompt(list, { name: "alpha", text: "3", source: "saved" }).map((p) => `${p.name}:${p.text}`)).toEqual([
      "alpha:3",
      "beta:1",
    ]);
  });

  test("save, list and delete go through acpmux; a refusal keeps the list", async () => {
    const calls: string[] = [];
    let held: SavedPrompt[] = [{ name: "kept", text: "k", source: "settings" }];
    setSavedPromptsTransport({
      list: async () => {
        calls.push("list");
        return { prompts: held };
      },
      save: async (name, text) => {
        calls.push(`save ${name}`);
        if (name === "bad") throw new Error("refused");
        const prompt = { name, text, source: "saved" as const, updatedAt: 1 };
        held = [...held, prompt];
        return { prompt };
      },
      remove: async (name) => {
        calls.push(`delete ${name}`);
        return { removed: true };
      },
    });
    await refreshSavedPrompts();
    await savePrompt(" new ", "text");
    await expect(savePrompt("bad", "x")).rejects.toThrow("refused");
    await deletePrompt("kept");
    expect(calls).toEqual(["list", "save new", "save bad", "delete kept"]);
    expect(savedPromptsNow().map((prompt) => prompt.name)).toEqual(["new"]);
  });

  test("another acpmux starts from no list, and the old one's late answer is dropped", async () => {
    let answer: (value: unknown) => void = () => undefined;
    const old = {
      list: () => new Promise<unknown>((resolve) => (answer = resolve)),
      save: async () => ({}),
      remove: async () => ({}),
    };
    setSavedPromptsTransport(old);
    seedSavedPrompts([{ name: "old machine's", text: "t", source: "saved" }]);
    setSavedPromptsTransport({ list: async () => ({ prompts: [] }), save: async () => ({}), remove: async () => ({}) });
    expect(savedPromptsNow()).toEqual([]);
    answer({ prompts: [{ name: "late", text: "t", source: "saved" }] });
    await Promise.resolve();
    expect(savedPromptsNow()).toEqual([]);
  });

  test("a list read while a save was out never takes the save back; the list is read again", async () => {
    const lists: ((value: unknown) => void)[] = [];
    const daemon: SavedPrompt[] = [];
    setSavedPromptsTransport({
      list: () => new Promise<unknown>((resolve) => lists.push(resolve)),
      save: async (name: string, text: string) => {
        const prompt: SavedPrompt = { name, text, source: "saved" };
        daemon.push(prompt);
        return { prompt };
      },
      remove: async () => ({}),
    });
    // The connection's first read, still out while the save lands.
    const read = refreshSavedPrompts();
    await savePrompt("fresh", "text");
    expect(savedPromptsNow().map((prompt) => prompt.name)).toEqual(["fresh"]);
    lists.shift()!({ prompts: [] });
    for (let turn = 0; turn < 5 && !lists.length; turn++) await Promise.resolve();
    expect(savedPromptsNow().map((prompt) => prompt.name)).toEqual(["fresh"]);
    // The read again answers with what acpmux holds now.
    lists.shift()!({ prompts: daemon });
    await read;
    expect(savedPromptsNow().map((prompt) => prompt.name)).toEqual(["fresh"]);
  });
  test("a pick mid-word replaces the whole /word", () => {
    expect(wordEnd("/standup later", 4)).toBe(8);
    expect(wordEnd("/sta", 4)).toBe(4);
    expect(wordEnd("say /st\nmore", 7)).toBe(7);
  });
});
