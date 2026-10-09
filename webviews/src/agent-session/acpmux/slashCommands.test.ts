import { describe, expect, test } from "bun:test";
import { applyCommand, commandsFromUpdate, matchCommands, slashQuery, type SlashCommand } from "./slashCommands";

const commands: SlashCommand[] = [
  { name: "compact", description: "Summarize the conversation" },
  { name: "review", description: "Review changes", hint: "branch or PR" },
  { name: "pr-comments", description: "Read PR comments" },
  { name: "clear", description: "Start over" },
];

describe("slash commands", () => {
  test("reads an available_commands_update and ignores other updates", () => {
    const update = {
      sessionUpdate: "available_commands_update",
      availableCommands: [
        { name: "/review", description: "Review", input: { hint: " branch " } },
        { name: "", description: "nameless" },
        { name: "init", description: "Init", input: null },
      ],
    };
    expect(commandsFromUpdate(update)).toEqual([
      { name: "review", description: "Review", hint: "branch", source: "agent" },
      { name: "init", description: "Init", hint: undefined, source: "agent" },
    ]);
    expect(commandsFromUpdate({ sessionUpdate: "agent_message_chunk" })).toBeUndefined();
  });

  test("the menu opens only for a leading /word before the caret", () => {
    expect(slashQuery("/", 1)).toBe("");
    expect(slashQuery("/rev", 4)).toBe("rev");
    expect(slashQuery("/rev", 2)).toBe("r");
    expect(slashQuery("/review main", 12)).toBeUndefined();
    expect(slashQuery("say /rev", 8)).toBeUndefined();
    expect(slashQuery("\n/rev", 5)).toBeUndefined();
  });

  test("ranks prefix, then word start, then subsequence, keeping the agent's order", () => {
    expect(matchCommands(commands, "").map((match) => match.command.name)).toEqual([
      "compact",
      "review",
      "pr-comments",
      "clear",
    ]);
    expect(matchCommands(commands, "c").map((match) => match.command.name)).toEqual([
      "compact",
      "clear",
      "pr-comments",
    ]);
    const comments = matchCommands(commands, "com");
    expect(comments.map((match) => match.command.name)).toEqual(["compact", "pr-comments"]);
    expect(comments[1].ranges).toEqual([[3, 6]]);
    expect(matchCommands(commands, "rvw").map((match) => [match.command.name, match.ranges])).toEqual([
      [
        "review",
        [
          [0, 1],
          [2, 3],
          [5, 6],
        ],
      ],
    ]);
    expect(matchCommands(commands, "xyz")).toEqual([]);
    const skills = [
      { name: "refactor-drive", description: "" },
      { name: "$review-bot-rules", description: "" },
    ];
    expect(matchCommands(skills, "rev").map((match) => match.command.name)).toEqual([
      "$review-bot-rules",
      "refactor-drive",
    ]);
  });

  test("picking a command replaces the typed word and leaves room for arguments", () => {
    expect(applyCommand("/rev", 4, commands[1])).toEqual({ text: "/review ", caret: 8 });
    expect(applyCommand("/re main", 3, commands[1])).toEqual({ text: "/review main", caret: 8 });
  });
});
