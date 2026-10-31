import { translate, type Translate } from "./i18n";
import type { SlashCommand } from "./slashCommands";

/**
 * The + menu's groups, top to bottom (Leo, 2026-10-31: "our + button is ass" / "inside chat and in
 * the composer it's ass"; the reference is ChatGPT's + menu): attach first, then the composer's own
 * actions (Plan, Goal, the project, @ and the one Skills… row), then the searches, then the host's
 * catalog groups. Skills are never rows here: they live under / (the slash list), which Skills…
 * opens.
 */
export const COMPOSER_PLUS_SECTIONS = ["attach", "add", "files", "tools", "apps", "sessions", "tabs"] as const;
export type ComposerPlusSection = (typeof COMPOSER_PLUS_SECTIONS)[number];

export type ComposerPlusAction =
  | { kind: "command"; id: string; modeId?: string }
  | { kind: "slash"; command: SlashCommand };

export type ComposerPlusEntry = {
  id: string;
  section: ComposerPlusSection;
  name: string;
  description: string;
  icon: string;
  keywords: readonly string[];
  action: ComposerPlusAction;
};

export type ComposerPlusExtension = Omit<ComposerPlusEntry, "section"> & {
  section: Exclude<ComposerPlusSection, "attach" | "add">;
};

export type ComposerPlusRegistryOptions = {
  commands?: readonly SlashCommand[];
  translate?: Translate;
  canCapture?: boolean;
  canChooseProject?: boolean;
  planMode?: { id: string; name: string; description: string };
  extensions?: readonly ComposerPlusExtension[];
};

const COMMANDS = {
  attachFiles: "composer.attachFiles",
  attachScreenshot: "composer.attachScreenshot",
  attachWindow: "composer.attachWindow",
  chooseProject: "composer.chooseProject",
  planMode: "composer.planMode",
  mention: "composer.mention",
  commands: "composer.commands",
  searchFiles: "searchFiles",
} as const;

const staticRows: readonly ComposerPlusEntry[] = [
  {
    id: "add.files",
    section: "attach",
    // Named from the pane's table when the registry is built (`composer.attach`).
    name: "",
    description: "",
    icon: "file",
    keywords: ["attach", "upload", "folder", "files"],
    action: { kind: "command", id: COMMANDS.attachFiles },
  },
];

function extensionKey(entry: ComposerPlusEntry): string {
  return `${entry.section}:${entry.id}`;
}

export function composerPlusRegistry(options: ComposerPlusRegistryOptions = {}): ComposerPlusEntry[] {
  // Every label is the pane's table's, in the app's language (pane-english.test.ts).
  const t: Translate = options.translate ?? translate;
  const text = (key: Parameters<Translate>[0]) => t(key);
  const label = text;
  const description = text;
  const rows: ComposerPlusEntry[] = staticRows.map((row) => ({
    ...row,
    name: label("composer.attach"),
  }));

  if (options.canCapture !== false) {
    rows.push(
      {
        id: "add.screenshot",
        section: "attach",
        name: label("composer.attachScreenshot"),
        description: "",
        icon: "site.permission.camera",
        keywords: ["capture", "screen", "image"],
        action: { kind: "command", id: COMMANDS.attachScreenshot },
      },
      {
        id: "add.window",
        section: "attach",
        name: label("composer.attachWindow"),
        description: "",
        icon: "site.permission.windowmanagement",
        keywords: ["capture", "window", "image"],
        action: { kind: "command", id: COMMANDS.attachWindow },
      },
    );
  }

  if (options.planMode) {
    rows.push({
      id: `add.mode.${options.planMode.id}`,
      section: "add",
      name: options.planMode.name,
      description: options.planMode.description,
      icon: "mode.plan",
      keywords: ["plan", "mode", "read", "planning"],
      action: { kind: "command", id: COMMANDS.planMode, modeId: options.planMode.id },
    });
  }

  const goalCommand = options.commands?.find((command) => command.name.toLowerCase() === "goal");
  if (goalCommand) {
    rows.push({
      id: "add.goal",
      section: "add",
      name: label("goal.label"),
      description: description("goal.label"),
      icon: "agent.chat",
      keywords: ["goal", "objective", "task"],
      action: { kind: "slash", command: goalCommand },
    });
  }

  if (options.canChooseProject) {
    rows.push({
      id: "add.project",
      section: "add",
      name: label("project.choose"),
      description: "",
      icon: "folder",
      keywords: ["project", "folder", "cwd", "workspace"],
      action: { kind: "command", id: COMMANDS.chooseProject },
    });
  }

  rows.push(
    {
      id: "add.mention",
      section: "add",
      name: label("composer.mention"),
      description: "",
      icon: "composer.mention",
      keywords: ["@", "mention", "file", "chat"],
      action: { kind: "command", id: COMMANDS.mention },
    },
    // Skills… (and every other slash command) is one row that opens the searchable slash list; a
    // skill is never a row of its own here, however many the agent advertises.
    {
      id: "add.commands",
      section: "add",
      name: label("composer.plusSkills"),
      description: description("composer.plusSkillsHint"),
      icon: "terminal",
      keywords: ["/", "slash", "commands", "skills"],
      action: { kind: "command", id: COMMANDS.commands },
    },
  );

  rows.push({
    id: "files.search",
    section: "files",
    name: label("files.search"),
    description: "",
    icon: "search",
    keywords: ["files", "chats", "search", "context"],
    action: { kind: "command", id: COMMANDS.searchFiles },
  });

  const seen = new Set<string>();
  const extensions = [...(options.extensions ?? [])];
  const all = [...rows, ...extensions];
  return all.filter((entry) => {
    if (!entry.id || !entry.name.trim()) return false;
    const key = extensionKey(entry);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/**
 * The app's search pages the + menu opens (the ChatGPT desktop app's + searches): the command
 * palette's chats page and its History search page. Both ids are app actions an agent tab may run
 * (AgentPaneModel.paletteActions); a host that cannot run them leaves these rows out.
 */
export const PLUS_SEARCH_ACTIONS = { chats: "agentPane.searchChats", pages: "history.search" } as const;

export function composerPlusSearchExtensions(t: Translate = translate): ComposerPlusExtension[] {
  return [
    {
      id: PLUS_SEARCH_ACTIONS.chats,
      section: "files",
      name: t("sidebar.search"),
      description: t("composer.plusChatsHint"),
      icon: "agent.chat.list",
      keywords: ["chats", "conversations", "search"],
      action: { kind: "command", id: PLUS_SEARCH_ACTIONS.chats },
    },
    {
      id: PLUS_SEARCH_ACTIONS.pages,
      section: "files",
      name: t("composer.plusSearchPages"),
      description: t("composer.plusPagesHint"),
      icon: "history",
      keywords: ["pages", "history", "browser", "web", "search"],
      action: { kind: "command", id: PLUS_SEARCH_ACTIONS.pages },
    },
  ];
}

export function composerPlusSections(
  entries: readonly ComposerPlusEntry[],
): Map<ComposerPlusSection, ComposerPlusEntry[]> {
  const sections = new Map<ComposerPlusSection, ComposerPlusEntry[]>(
    COMPOSER_PLUS_SECTIONS.map((section) => [section, []]),
  );
  for (const entry of entries) sections.get(entry.section)?.push(entry);
  return sections;
}

export const COMPOSER_PLUS_MOTION = "none" as const;

export function runComposerPlusAction(
  action: ComposerPlusAction,
  handlers: {
    command(id: string, modeId?: string): void;
    extension?(id: string): void;
    slash(command: SlashCommand): void;
  },
): boolean {
  if (action.kind === "slash") {
    handlers.slash(action.command);
    return true;
  }
  if (Object.values(COMMANDS).includes(action.id as (typeof COMMANDS)[keyof typeof COMMANDS])) {
    handlers.command(action.id, action.modeId);
    return true;
  }
  if (!handlers.extension) return false;
  handlers.extension(action.id);
  return true;
}

export type NativeComposerAction = {
  id: string;
  section: "tools" | "apps" | "sessions" | "tabs";
  name: string;
  description: string;
  icon: string;
};

/** Only the app's narrow, bound catalog rows become + extensions. No page-invented action IDs. */
export function nativeComposerExtensions(value: unknown): ComposerPlusExtension[] {
  if (!Array.isArray(value)) return [];
  const sections = new Set(["tools", "apps", "sessions", "tabs"]);
  const icons: Record<string, string> = {
    openBrowser: "browser",
    computerUseFocus: "computeruse.observe",
    "palette.openCloudPane": "cloud",
    newSurface: "terminal",
    "app.command.run": "apps.stack",
    openSettings: "app.permissions",
    "search.chats": "agent.chat.list",
    "tab.search": "tunable.panes",
  };
  return value.flatMap((row): ComposerPlusExtension[] => {
    if (!row || typeof row !== "object") return [];
    const item = row as Record<string, unknown>;
    if (
      typeof item.id !== "string" ||
      typeof item.section !== "string" ||
      !sections.has(item.section) ||
      typeof item.name !== "string" ||
      typeof item.description !== "string" ||
      !item.id ||
      !item.name.trim() ||
      !item.description.trim()
    )
      return [];
    return [
      {
        id: item.id,
        section: item.section as NativeComposerAction["section"],
        name: item.name,
        description: item.description,
        icon: icons[item.id] ?? "terminal",
        keywords: [item.name, item.description],
        action: { kind: "command", id: item.id },
      },
    ];
  });
}
