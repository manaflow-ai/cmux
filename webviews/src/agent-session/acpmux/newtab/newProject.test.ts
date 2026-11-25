import { describe, expect, test } from "bun:test";
import {
  awaitProjectPreview,
  awaitsProjectPreview,
  newProjectPrompt,
  projectNameFrom,
  projectNameTyping,
  projectSlug,
  takeProjectPreview,
} from "./newProject";

/// The preview registry's deadline (newProject.ts PREVIEW_DEADLINE_MS).
const DEADLINE_MS = 30 * 60_000;

describe("projectSlug", () => {
  test("lower case, other runs of characters as one -", () => {
    expect(projectSlug("Habit Tracker")).toBe("habit-tracker");
    expect(projectSlug("my  cool / app!")).toBe("my-cool-app");
    expect(projectSlug("a--b")).toBe("a-b");
  });

  test("keeps letters, digits, . and _", () => {
    expect(projectSlug("api_v2.service")).toBe("api_v2.service");
  });

  test("no leading or trailing . or -", () => {
    expect(projectSlug(".hidden")).toBe("hidden");
    expect(projectSlug("--name--")).toBe("name");
    expect(projectSlug("  spaced out  ")).toBe("spaced-out");
    expect(projectSlug("dots...")).toBe("dots");
  });

  test("accents become their plain letters", () => {
    expect(projectSlug("Café Crème")).toBe("cafe-creme");
    expect(projectSlug("Ångström")).toBe("angstrom");
  });

  test("nothing a folder name takes is empty", () => {
    expect(projectSlug("")).toBe("");
    expect(projectSlug("!!!")).toBe("");
    expect(projectSlug("日本語")).toBe("");
  });

  test("at most `max` characters, with no - left at the cut", () => {
    expect(projectSlug("a".repeat(80))).toHaveLength(64);
    expect(projectSlug("abc-def", 4)).toBe("abc");
    expect(projectSlug("abcdef", 3)).toBe("abc");
  });
});

describe("projectNameTyping", () => {
  test("lower case, other characters as -", () => {
    expect(projectNameTyping("My Project")).toBe("my-project");
    expect(projectNameTyping("hello world!")).toBe("hello-world-");
  });

  test("keeps a typed - at the end, so one can be typed between words", () => {
    expect(projectNameTyping("habit-")).toBe("habit-");
    expect(projectNameTyping("habit ")).toBe("habit-");
  });

  test("no leading . or -", () => {
    expect(projectNameTyping("-name")).toBe("name");
    expect(projectNameTyping(".name")).toBe("name");
  });

  test("keeps letters, digits, ., _ and -", () => {
    expect(projectNameTyping("api_v2.service-x")).toBe("api_v2.service-x");
  });

  test("at most 64 characters", () => {
    expect(projectNameTyping("a".repeat(80))).toHaveLength(64);
  });
});

describe("projectNameFrom", () => {
  test.each([
    ["a habit tracker web app", "habit-tracker"],
    ["Build me a todo list with tags", "todo-list"],
    ["Make an expense splitter for roommates", "expense-splitter"],
    ["please create a recipe box that imports photos", "recipe-box"],
    ["Pomodoro timer", "pomodoro-timer"],
    ["Write a markdown blog engine. It should use SQLite.", "markdown-blog-engine"],
    ["a simple web app", "simple-web-app"],
    ["Café menu", "cafe-menu"],
    ["", "project"],
    ["   ", "project"],
    ["!?", "project"],
  ])("%j is %j", (prompt, name) => {
    expect(projectNameFrom(prompt)).toBe(name);
  });

  test("up to four words", () => {
    expect(projectNameFrom("one two three four five six")).toBe("one-two-three-four");
  });

  test("the first line only", () => {
    expect(projectNameFrom("chess clock\nwith increments and delays")).toBe("chess-clock");
  });

  test("at most 40 characters, and a folder name acpmux takes", () => {
    const name = projectNameFrom("Supercalifragilisticexpialidocious extraordinarily magnificent dashboards");
    expect(name.length).toBeLessThanOrEqual(40);
    expect(name).toBe(projectSlug(name));
    expect(name).not.toMatch(/-$/);
  });
});

describe("newProjectPrompt", () => {
  test("the person's words first, then the new-folder line", () => {
    const prompt = newProjectPrompt("a habit tracker web app");
    expect(prompt.startsWith("a habit tracker web app\n\n")).toBe(true);
    expect(prompt).toContain("new, empty project folder");
    expect(prompt).toContain("local URL");
  });

  test("trailing space of the prompt goes", () => {
    expect(newProjectPrompt("make a game  \n").startsWith("make a game\n\n(")).toBe(true);
  });
});

describe("the preview registry", () => {
  test("true once, then false", () => {
    const folder = "/Users/you/projects/once";
    awaitProjectPreview(folder, 1_000);
    expect(awaitsProjectPreview(folder, 2_000)).toBe(true);
    // Asking does not take it.
    expect(awaitsProjectPreview(folder, 2_000)).toBe(true);
    expect(takeProjectPreview(folder, 2_000)).toBe(true);
    expect(takeProjectPreview(folder, 2_000)).toBe(false);
    expect(awaitsProjectPreview(folder, 2_000)).toBe(false);
  });

  test("false past the deadline, and the folder leaves", () => {
    const folder = "/Users/you/projects/late";
    awaitProjectPreview(folder, 0);
    expect(awaitsProjectPreview(folder, DEADLINE_MS)).toBe(true);
    expect(awaitsProjectPreview(folder, DEADLINE_MS + 1)).toBe(false);
    // The late ask dropped it: even a time inside the deadline no longer finds it.
    expect(takeProjectPreview(folder, 1)).toBe(false);
  });

  test("a take past the deadline is false", () => {
    const folder = "/Users/you/projects/late-take";
    awaitProjectPreview(folder, 0);
    expect(takeProjectPreview(folder, DEADLINE_MS + 1)).toBe(false);
    expect(awaitsProjectPreview(folder, 1)).toBe(false);
  });

  test("another folder, or none, waits for nothing", () => {
    const folder = "/Users/you/projects/mine";
    awaitProjectPreview(folder, 0);
    expect(takeProjectPreview("/Users/you/projects/other", 1)).toBe(false);
    expect(awaitsProjectPreview(undefined, 1)).toBe(false);
    expect(takeProjectPreview(undefined, 1)).toBe(false);
    expect(takeProjectPreview("", 1)).toBe(false);
    expect(takeProjectPreview(folder, 1)).toBe(true);
  });

  test("awaiting again restarts the deadline", () => {
    const folder = "/Users/you/projects/again";
    awaitProjectPreview(folder, 0);
    awaitProjectPreview(folder, DEADLINE_MS);
    expect(awaitsProjectPreview(folder, DEADLINE_MS + 1)).toBe(true);
    expect(takeProjectPreview(folder, DEADLINE_MS + 1)).toBe(true);
  });
});
