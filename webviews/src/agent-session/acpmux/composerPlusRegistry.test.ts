import { expect, test } from "bun:test";
import {
  COMPOSER_PLUS_MOTION,
  COMPOSER_PLUS_SECTIONS,
  composerPlusRegistry,
  composerPlusSections,
} from "./composerPlusRegistry";

test("the plus registry exposes the Add and Files sections in command order", () => {
  const rows = composerPlusRegistry({
    canChooseProject: true,
    canSetGoal: true,
    planMode: { id: "plan", name: "Plan mode", description: "Think through the work before editing" },
  });

  expect(COMPOSER_PLUS_MOTION).toBe("none");
  expect(rows.map((row) => row.section)).toEqual([
    "add",
    "add",
    "add",
    "add",
    "add",
    "add",
    "files",
  ]);
  expect(rows.slice(0, 6).map((row) => row.name)).toEqual([
    "Files and folders",
    "Attach a screenshot",
    "Attach a window",
    "Choose a project",
    "Plan mode",
    "Set a goal",
  ]);
  expect(rows.at(-1)?.name).toBe("Files and chats");
  expect(rows.every((row) => row.icon && row.description && row.action)).toBe(true);
});

test("capture and optional goal rows are omitted when the host lacks those capabilities", () => {
  const rows = composerPlusRegistry({ canCapture: false, canSetGoal: false });
  expect(rows.map((row) => row.id)).toEqual(["add.files", "files.search"]);
});

test("skills and prompts reuse their slash command while agent commands stay in the slash menu", () => {
  const command = { name: "review", description: "Review the current change", source: "skill" as const };
  const rows = composerPlusRegistry({
    commands: [
      command,
      { name: "build", description: "Build the project", source: "agent" },
      { name: "$draw", description: "Draw a sketch", source: "prompt" },
    ],
  });

  const skills = rows.filter((row) => row.section === "add" && row.id.startsWith("add.skill."));
  expect(skills.map((row) => row.name)).toEqual(["/review", "/$draw"]);
  expect(skills[0]?.action).toEqual({ kind: "slash", command });
  expect(rows.some((row) => row.name === "/build")).toBe(false);
});

test("host extensions keep their palette action and deduplicate stable ids", () => {
  const rows = composerPlusRegistry({
    extensions: [
      {
        id: "browser",
        section: "tools",
        name: "Browser",
        description: "Control the in-app browser",
        icon: "browser",
        keywords: ["web"],
        action: { kind: "command", id: "palette.openBrowser" },
      },
      {
        id: "browser",
        section: "tools",
        name: "Browser duplicate",
        description: "Should be ignored",
        icon: "browser",
        keywords: [],
        action: { kind: "command", id: "other" },
      },
      {
        id: "recent-1",
        section: "sessions",
        name: "Recent chat",
        description: "Open a recent chat",
        icon: "agent.chat",
        keywords: ["session"],
        action: { kind: "command", id: "palette.openChat" },
      },
      {
        id: "tab-1",
        section: "tabs",
        name: "Browser tab",
        description: "Attach an open tab",
        icon: "browser",
        keywords: ["tab"],
        action: { kind: "command", id: "palette.attachTab" },
      },
    ],
  });

  expect(rows.filter((row) => row.id === "browser")).toHaveLength(1);
  expect(rows.find((row) => row.id === "browser")?.action).toEqual({
    kind: "command",
    id: "palette.openBrowser",
  });
  expect([...composerPlusSections(rows).keys()]).toEqual([...COMPOSER_PLUS_SECTIONS]);
  expect(composerPlusSections(rows).get("tools")?.map((row) => row.name)).toEqual(["Browser"]);
  expect(composerPlusSections(rows).get("sessions")?.map((row) => row.name)).toEqual(["Recent chat"]);
  expect(composerPlusSections(rows).get("tabs")?.map((row) => row.name)).toEqual(["Browser tab"]);
});
