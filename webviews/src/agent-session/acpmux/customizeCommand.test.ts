import { describe, expect, test } from "bun:test";
import { customizeMessage, customizePrompt, customizeVerb, shellWord, newChatRunsElsewhere } from "./customizeCommand";

describe("/customize", () => {
  test("a wish asks the agent to follow the brief, quoted as one shell word", () => {
    const prompt = customizePrompt("make the sidebar compact, don't touch the theme");
    expect(prompt.split("\n")[0]).toBe("Customize cmux: make the sidebar compact, don't touch the theme");
    expect(prompt).toContain("`cmux customize brief -- 'make the sidebar compact, don'\\''t touch the theme'`");
    expect(prompt).toContain("Do not apply or discard it");
  });

  test("a verb runs that verb, and nothing typed is the status", () => {
    expect(customizeVerb("")).toBe("cmux customize status");
    expect(customizeVerb("apply")).toBe("cmux customize apply");
    expect(customizeVerb("Discard")).toBe("cmux customize discard");
    expect(customizeVerb("undo")).toBe("cmux customize rollback");
    expect(customizeVerb("rollback #3")).toBe("cmux customize rollback 3");
    expect(customizeVerb("show 2")).toBe("cmux customize show 2");
    expect(customizeVerb("history")).toBe("cmux customize generations");
    expect(customizeVerb("save compact-night small and dark")).toBe(
      "cmux customize save compact-night 'small and dark'",
    );
    expect(customizeVerb("use compact-night")).toBe("cmux customize use compact-night");
    expect(customizePrompt("apply")).toBe("Run `cmux customize apply` and tell me what it says, in a sentence or two.");
  });

  test("words after a verb that are not its argument make it a wish", () => {
    for (const wish of [
      "apply a night theme",
      "use a darker theme",
      "show 2 columns",
      "discard the tab bar",
      "rollback three",
    ])
      expect(customizeVerb(wish)).toBeUndefined();
    // After `save NAME` the rest is a note, as in the CLI, and is one quoted word.
    expect(customizeVerb("save space in the sidebar; $(rm)")).toBe("cmux customize save space 'in the sidebar; $(rm)'");
    expect(shellWord('a `b` $(c) "d"')).toBe("'a `b` $(c) \"d\"'");
  });

  test("a chat that has not started says where it will run by what is picked", () => {
    expect(newChatRunsElsewhere({})).toBe(false);
    expect(newChatRunsElsewhere({ mode: "persistent", environmentKind: "local" })).toBe(false);
    for (const pick of [
      { mode: "cloud" as const },
      { mode: "sandboxed" as const },
      { machine: true },
      { environmentKind: "ssh" },
      { environmentKind: "cloud" },
    ])
      expect(newChatRunsElsewhere(pick)).toBe(true);
    // A started chat answers by its own host (`inCloud`), whatever the picker last showed.
    expect(newChatRunsElsewhere({ started: true, mode: "cloud" })).toBe(false);
  });

  test("only a whole /customize message is taken", () => {
    expect(customizeMessage("/customize apply")).toContain("cmux customize apply");
    expect(customizeMessage("  /customize\nbigger text  ")).toContain("Customize cmux: bigger text");
    expect(customizeMessage("/customizer x")).toBeUndefined();
    expect(customizeMessage("please /customize x")).toBeUndefined();
  });
});
