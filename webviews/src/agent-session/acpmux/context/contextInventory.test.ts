// l10n-allow-file: test fixtures.
import { expect, test } from "bun:test";
import { grouped, guidanceDraft, parseInventory } from "./contextInventory";

const answer = {
  parts: [
    {
      id: "harness-category-0-system",
      source: "harness",
      label: "System prompt",
      tokens: 3100,
      included: true,
      measurement: "measured",
    },
    { id: "memory-0", source: "memory", label: "CLAUDE.md", tokens: 200, included: true, measurement: "measured" },
    {
      id: "cmux-default-override",
      source: "cmux-default",
      label: "cmux guidance",
      tokens: 40,
      included: true,
      editable: true,
      measurement: "estimated",
      channel: "user-context",
      text: "Read early.",
    },
    {
      id: "cmux-folder-instructions",
      source: "cmux-folder",
      label: "Folder instructions",
      tokens: 10,
      measurement: "estimated",
      text: "AGENTS.md text",
    },
    { id: "", source: "harness" },
    "not a part",
  ],
  totalTokens: 3350,
  providerTotalTokens: 3350,
  cmuxTokens: 50,
  maxTokens: 200000,
  canEditOverrides: true,
  overrides: {
    defaultText: "Read early.",
    user: "Every chat.",
    project: null,
    projectKey: "k",
    cwd: "/w",
    parts: {
      "cmux-system-prompt": {
        label: "Preset system prompt",
        defaultText: "You are a reviewer.",
        user: null,
        project: "Folder preset.",
      },
    },
  },
};

test("parses acpmux's inventory and drops malformed parts", () => {
  const inventory = parseInventory(answer)!;
  expect(inventory.parts.map((p) => p.id)).toEqual([
    "harness-category-0-system",
    "memory-0",
    "cmux-default-override",
    "cmux-folder-instructions",
  ]);
  expect(inventory.parts[2]).toMatchObject({ editable: true, measurement: "estimated", text: "Read early." });
  expect(inventory.maxTokens).toBe(200000);
  expect(inventory.canEdit).toBe(true);
  expect(inventory.defaultText).toBe("Read early.");
  expect(inventory.user).toBe("Every chat.");
  expect(inventory.project).toBeUndefined();
  expect(inventory.prompts["cmux-system-prompt"]).toEqual({
    label: "Preset system prompt",
    defaultText: "You are a reviewer.",
    project: "Folder preset.",
  });
});

test("a value that is not an inventory parses to none", () => {
  expect(parseInventory(null)).toBeUndefined();
  expect(parseInventory({ parts: "x" })).toBeUndefined();
});

test("a remote answer has counts but no text and no editing", () => {
  const inventory = parseInventory({
    ...answer,
    canEditOverrides: false,
    parts: answer.parts.slice(0, 3).map((p) => (typeof p === "object" ? { ...p, text: undefined } : p)),
    overrides: { user: null, project: null, projectKey: "", cwd: "", parts: {} },
  })!;
  expect(inventory.canEdit).toBe(false);
  expect(inventory.defaultText).toBeUndefined();
  expect(inventory.parts.every((p) => p.text === undefined)).toBe(true);
});

test("groups cmux's additions apart from the harness's own parts", () => {
  const groups = grouped(parseInventory(answer)!);
  expect(groups.map((g) => [g.id, g.parts.map((p) => p.id)])).toEqual([
    ["cmux", ["cmux-default-override", "cmux-folder-instructions"]],
    ["harness", ["harness-category-0-system"]],
    ["memory", ["memory-0"]],
  ]);
});

test("the editor starts from the scope's saved text, then what a new chat there gets", () => {
  const inventory = parseInventory(answer)!;
  expect(guidanceDraft(inventory, "user")).toBe("Every chat.");
  // No folder text saved: a folder's new chat gets the text for every chat.
  expect(guidanceDraft(inventory, "project")).toBe("Every chat.");
  expect(guidanceDraft({ ...inventory, user: undefined }, "user")).toBe("Read early.");
  expect(guidanceDraft({ ...inventory, project: "" }, "project")).toBe("");
});
