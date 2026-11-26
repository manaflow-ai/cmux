import { describe, expect, test } from "bun:test";
import { extensionChipsFrom, withChipText } from "./extensionChipModel";

describe("extension chips", () => {
  test("reads the chips of an apps.composer.list reply", () => {
    const chips = extensionChipsFrom({
      commands: [],
      chips: [
        {
          app: "local/standup",
          extension: "Standup",
          id: "branch",
          label: "Branch",
          detail: "Name it",
          insert: "Work on the branch.",
        },
        { app: "local/standup", extension: "Standup", id: "branch", label: "Again", insert: "Other." },
        { app: "local/standup", id: "", label: "No id", insert: "x" },
        { app: "local/standup", id: "nolabel", insert: "x" },
        { app: "local/standup", id: "noinsert", label: "No insert" },
        "junk",
      ],
    });
    expect(chips).toEqual([
      {
        app: "local/standup",
        extension: "Standup",
        id: "branch",
        label: "Branch",
        detail: "Name it",
        insert: "Work on the branch.",
      },
    ]);
  });

  test("no chips key, or a null reply, is no chips", () => {
    expect(extensionChipsFrom({ commands: [] })).toEqual([]);
    expect(extensionChipsFrom(null)).toEqual([]);
  });

  test("a chip's text goes in at the caret, set off by spaces", () => {
    expect(withChipText("", 0, "Hi.")).toEqual({ text: "Hi.", caret: 3 });
    expect(withChipText("fix it", 6, "Hi.")).toEqual({ text: "fix it Hi.", caret: 10 });
    expect(withChipText("fix it", 3, "Hi.")).toEqual({ text: "fix Hi. it", caret: 7 });
    expect(withChipText("fix ", 4, "Hi.")).toEqual({ text: "fix Hi.", caret: 7 });
  });
});
