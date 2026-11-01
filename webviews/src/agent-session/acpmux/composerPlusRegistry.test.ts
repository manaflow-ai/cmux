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
import { composerPlusMenuSections } from "./ComposerPlusMenu";
import { composerPlusCommands } from "./composerPlusCommands.experiment";
import { loadRecentCommandNames, PLUS_RECENT_COMMANDS, recentCommands, rememberRecentCommand } from "./recentCommands";

test("the plus registry puts attach first, then the composer's actions, then the searches", () => {
  const rows = composerPlusRegistry({
    canChooseProject: true,
    commands: [{ name: "goal", description: "Set goal", source: "agent" }],
    planMode: { id: "plan", name: "Plan mode", description: "Think through the work before editing" },
  });
  expect(COMPOSER_PLUS_MOTION).toBe("none");
  expect(rows.map((row) => row.section)).toEqual([
    "attach",
    "attach",
    "attach",
    "add",
    "add",
    "add",
    "add",
    "commands",
    "files",
  ]);
  expect(rows.map((row) => row.name)).toEqual([
    "Attach files or images",
    "Attach Screenshot…",
    "Attach Window…",
    "Plan mode",
    "Goal",
    "Choose project",
    "Mention a file or folder",
    "Commands and skills…",
    "Search files",
  ]);
  expect(rows.every((row) => row.icon && row.action)).toBe(true);
  expect(rows.filter((row) => row.description).map((row) => row.id)).toEqual(["add.mode.plan", "add.goal"]);
  const css = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
  // No header band in the + menu (Leo 2026-10-31: the Search header read as a grey input).
  expect(css).not.toMatch(/\.acpmux-composer-plus \.acpmux-menu-header\s*\{/);
  // A bounded panel that scrolls inside, and popupHost.ts keeps it in the page up to that bound.
  expect(css).toMatch(
    /\.acpmux-composer-plus \.acpmux-menu\s*\{[^}]*--popup-scroll-cap:360px;[^}]*max-height:min\(360px,calc\(100vh - 16px\)\)/,
  );
});

test("capture and optional goal rows are omitted when the host lacks those capabilities", () => {
  const rows = composerPlusRegistry({ canCapture: false });
  expect(rows.map((row) => row.id)).toEqual(["add.files", "add.mention", "add.commands", "files.search"]);
});

test("skills are never + rows: one Commands and skills… row opens the slash list, however many there are", () => {
  const skills = Array.from({ length: 30 }, (_, index) => ({
    name: `skill-${index}`,
    description: `Skill ${index}`,
    source: "skill" as const,
  }));
  const rows = composerPlusRegistry({
    commands: [...skills, { name: "$draw", description: "Draw a sketch", source: "prompt" }],
  });
  expect(rows.some((row) => row.name.startsWith("/") || row.id.startsWith("add.skill."))).toBe(false);
  const skillsRow = rows.filter((row) => row.id === "add.commands");
  expect(skillsRow.map((row) => [row.name, row.description, row.action])).toEqual([
    ["Commands and skills…", "", { kind: "command", id: "composer.commands" }],
  ]);
  expect(rows).toHaveLength(6);
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

test("the + menu lists at most PLUS_RECENT_COMMANDS recent commands, then the Commands and skills… row", () => {
  // Leo, 2026-11-01: "our + button results are still really bad" (every skill was a + row).
  const skills = Array.from({ length: 40 }, (_, index) => ({
    name: `aws-skill-${index}`,
    description: `Skill ${index}`,
    source: "skill" as const,
  }));
  const goal = { name: "goal", description: "Set a goal", source: "agent" as const };
  const commands = [goal, ...skills];
  const names = ["goal", "aws-skill-7", "gone", "aws-skill-3", "aws-skill-7", "aws-skill-1", "aws-skill-2"];
  const recents = recentCommands(names, commands);
  // Goal has its own row; a name the agent no longer lists and a repeat are skipped.
  expect(recents.map((command) => command.name)).toEqual(["aws-skill-7", "aws-skill-3", "aws-skill-1"]);
  const rows = composerPlusRegistry({ commands, recentCommands: [...recents, ...skills] });
  const group = composerPlusSections(rows).get("commands") ?? [];
  expect(group.length).toBeLessThanOrEqual(PLUS_RECENT_COMMANDS + 1);
  expect(group.map((row) => row.name)).toEqual([
    "/aws-skill-7",
    "/aws-skill-3",
    "/aws-skill-1",
    "Commands and skills…",
  ]);
  // Every row of + together stays a short menu, however many skills the agent advertises.
  expect(rows.length).toBeLessThanOrEqual(12);
  expect(rows.filter((row) => row.name.startsWith("/"))).toHaveLength(PLUS_RECENT_COMMANDS);
  // A recent row writes its command like Goal; the row opens the slash list.
  const slashed: string[] = [];
  const opened: string[] = [];
  for (const row of group)
    runComposerPlusAction(row.action, { command: (id) => opened.push(id), slash: (c) => slashed.push(c.name) });
  expect(slashed).toEqual(["aws-skill-7", "aws-skill-3", "aws-skill-1"]);
  expect(opened).toEqual(["composer.commands"]);
});

test("the shipped arm draws recents, then the row; the other arms move or drop the recents", () => {
  const commands = [
    { name: "review", description: "Review the diff" },
    { name: "deploy", description: "Deploy", source: "skill" as const },
  ];
  const rows = composerPlusRegistry({ commands, recentCommands: commands });
  const group = (arm?: Parameters<typeof composerPlusMenuSections>[2]) =>
    composerPlusMenuSections(rows, false, arm)
      .find((section) => section.section === "commands")
      ?.choices.map((choice) => choice.id);
  expect(composerPlusCommands.defaultArm).toBe("recents-then-row");
  expect(group()).toEqual(["commands.recent.review", "commands.recent.deploy", "add.commands"]);
  expect(group("row-then-recents")).toEqual(["add.commands", "commands.recent.review", "commands.recent.deploy"]);
  expect(group("row-only")).toEqual(["add.commands"]);
});

test("recent commands are kept most recent first, without repeats", () => {
  const store = new Map<string, string>();
  const previous = globalThis.localStorage;
  globalThis.localStorage = {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
  } as unknown as Storage;
  try {
    expect(loadRecentCommandNames()).toEqual([]);
    rememberRecentCommand("review");
    rememberRecentCommand("deploy");
    expect(rememberRecentCommand("review")).toEqual(["review", "deploy"]);
    expect(loadRecentCommandNames()).toEqual(["review", "deploy"]);
  } finally {
    globalThis.localStorage = previous;
  }
});
