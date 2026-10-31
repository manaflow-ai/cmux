import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  COMPOSER_PLUS_MOTION,
  COMPOSER_PLUS_SECTIONS,
  composerPlusRegistry,
  composerPlusSearchExtensions,
  composerPlusSections,
  nativeComposerExtensions,
  PLUS_SEARCH_ACTIONS,
  runComposerPlusAction,
} from "./composerPlusRegistry";

test("the plus registry exposes the Add and Files sections in command order", () => {
  const rows = composerPlusRegistry({
    canChooseProject: true,
    commands: [{ name: "goal", description: "Set goal", source: "agent" }],
    planMode: { id: "plan", name: "Plan mode", description: "Think through the work before editing" },
  });
  expect(COMPOSER_PLUS_MOTION).toBe("none");
  expect(rows.map((row) => row.section)).toEqual(["add", "add", "add", "add", "add", "add", "add", "add", "files"]);
  expect(rows.slice(0, 6).map((row) => row.name)).toEqual([
    "Attach files or images",
    "Attach Screenshot…",
    "Attach Window…",
    "Choose project",
    "Plan mode",
    "Goal",
  ]);
  expect(rows.at(-1)?.name).toBe("Search files");
  expect(rows.every((row) => row.icon && row.action)).toBe(true);
  expect(rows.filter((row) => row.description).map((row) => row.id)).toEqual(["add.mode.plan", "add.goal"]);
  const css = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
  expect(css).toMatch(
    /\.acpmux-composer-plus \.acpmux-menu-header\s*\{[^}]*background-image:linear-gradient\(var\(--surface-popup\),var\(--surface-popup\)\)/,
  );
  // The + menu is not held to half the window like other menus: in a short pane its Search rows
  // stay whole (composer-chip-press.test.ts presses every row at 760x600).
  expect(css).toMatch(/\.acpmux-composer-plus \.acpmux-menu\s*\{[^}]*max-height:min\(520px,calc\(100vh - 16px\)\)/);
});

test("capture and optional goal rows are omitted when the host lacks those capabilities", () => {
  const rows = composerPlusRegistry({ canCapture: false });
  expect(rows.map((row) => row.id)).toEqual(["add.files", "add.mention", "add.commands", "files.search"]);
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
  expect(
    composerPlusSections(rows)
      .get("tools")
      ?.map((row) => row.name),
  ).toEqual(["Browser"]);
  expect(
    composerPlusSections(rows)
      .get("sessions")
      ?.map((row) => row.name),
  ).toEqual(["Recent chat"]);
  expect(
    composerPlusSections(rows)
      .get("tabs")
      ?.map((row) => row.name),
  ).toEqual(["Browser tab"]);
});

test("the same registry action reaches the composer handler with its exact plan mode id", () => {
  const calls: string[] = [];
  const entries = composerPlusRegistry({
    canCapture: false,
    planMode: { id: "claude-plan", name: "Plan mode", description: "Plan without edits" },
  });
  const plan = entries.find((entry) => entry.id === "add.mode.claude-plan")!;
  expect(plan.action).toEqual({ kind: "command", id: "composer.planMode", modeId: "claude-plan" });
  expect(
    runComposerPlusAction(plan.action, {
      command: (id, modeId) => calls.push(`${id}:${modeId ?? ""}`),
      slash: () => calls.push("slash"),
    }),
  ).toBe(true);
  expect(calls).toEqual(["composer.planMode:claude-plan"]);
});

test("host palette actions dispatch through the extension handler", () => {
  const calls: string[] = [];
  expect(
    runComposerPlusAction(
      { kind: "command", id: "palette.openBrowser" },
      {
        command: () => calls.push("command"),
        extension: (id) => calls.push(id),
        slash: () => calls.push("slash"),
      },
    ),
  ).toBe(true);
  expect(calls).toEqual(["palette.openBrowser"]);
});

test("unknown actions cannot silently close the + menu", () => {
  expect(
    runComposerPlusAction(
      { kind: "command", id: "missing" },
      {
        command: () => undefined,
        slash: () => undefined,
      },
    ),
  ).toBe(false);
});

test("native catalog rows keep their real action ids and reject malformed rows", () => {
  const rows = nativeComposerExtensions([
    { id: "openBrowser", section: "tools", name: "New Browser Tab", description: "Open a browser tab", icon: "globe" },
    { id: "search.chats", section: "sessions", name: "Search Chats", description: "Find a chat", icon: "bubble.left" },
    { id: "unknown", section: "debug", name: "Debug", description: "Not a composer section" },
    { id: "", section: "tabs", name: "Empty", description: "No action" },
  ]);
  expect(rows.map((row) => [row.section, row.action])).toEqual([
    ["tools", { kind: "command", id: "openBrowser" }],
    ["sessions", { kind: "command", id: "search.chats" }],
  ]);
  expect(rows[0]?.icon).toBe("browser");
});

test("Search chats and Search pages dispatch the app's palette actions through the extension handler", () => {
  const rows = composerPlusRegistry({ extensions: composerPlusSearchExtensions() });
  const search = composerPlusSections(rows).get("files") ?? [];
  expect(search.map((row) => row.name)).toEqual(["Search files", "Search chats", "Search pages"]);
  const ran: string[] = [];
  const commands: string[] = [];
  for (const row of search)
    expect(
      runComposerPlusAction(row.action, {
        command: (id) => commands.push(id),
        extension: (id) => ran.push(id),
        slash: () => {},
      }),
    ).toBe(true);
  // Search files stays the composer's own file finder; the other two are app actions the pane may run
  // (AgentPaneModel.paletteActions), never ids the host refuses.
  expect(commands).toEqual(["searchFiles"]);
  expect(ran).toEqual([PLUS_SEARCH_ACTIONS.chats, PLUS_SEARCH_ACTIONS.pages]);
  const swift = readFileSync(
    new URL(
      "../../../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneModel+Actions.swift",
      import.meta.url,
    ),
    "utf8",
  );
  const allowed = /paletteActions: Set<String> = \[([^\]]*)\]/.exec(swift)?.[1] ?? "";
  for (const id of Object.values(PLUS_SEARCH_ACTIONS)) expect(allowed).toContain(`"${id}"`);
});
