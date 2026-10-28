import type { Translate } from "./i18n";
import type { SlashCommand } from "./slashCommands";

export const COMPOSER_PLUS_SECTIONS = ["add", "tools", "sessions", "tabs", "files"] as const;
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
  section: Exclude<ComposerPlusSection, "add">;
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
    section: "add",
    name: "Files and folders",
    description: "Attach files or folders as context",
    icon: "file",
    keywords: ["attach", "upload", "folder", "files"],
    action: { kind: "command", id: COMMANDS.attachFiles },
  },
];

function extensionKey(entry: ComposerPlusEntry): string {
  return `${entry.section}:${entry.id}`;
}

export function composerPlusRegistry(options: ComposerPlusRegistryOptions = {}): ComposerPlusEntry[] {
  const text = (key: Parameters<Translate>[0], fallback: string) => options.translate?.(key) ?? fallback;
  const label = text;
  const description = text;
  const rows: ComposerPlusEntry[] = staticRows.map((row) => ({
    ...row,
    name: label("composer.menu.attachFiles", row.name),
    description: description("summary.sources.attach", row.description),
  }));

  if (options.canCapture !== false) {
    rows.push(
      {
        id: "add.screenshot",
        section: "add",
        name: label("composer.attachScreenshot", "Attach a screenshot"),
        description: description("composer.attachScreenshot", "Capture the screen and attach it"),
        icon: "site.permission.camera",
        keywords: ["capture", "screen", "image"],
        action: { kind: "command", id: COMMANDS.attachScreenshot },
      },
      {
        id: "add.window",
        section: "add",
        name: label("composer.attachWindow", "Attach a window"),
        description: description("composer.attachWindow", "Capture a window and attach it"),
        icon: "site.permission.windowmanagement",
        keywords: ["capture", "window", "image"],
        action: { kind: "command", id: COMMANDS.attachWindow },
      },
    );
  }

  if (options.canChooseProject) {
    rows.push({
      id: "add.project",
      section: "add",
      name: label("project.choose", "Choose a project"),
      description: description("project.choose", "Pick the folder or cwd for this chat"),
      icon: "folder",
      keywords: ["project", "folder", "cwd", "workspace"],
      action: { kind: "command", id: COMMANDS.chooseProject },
    });
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
      name: label("goal.label", "Set a goal"),
      description: description("goal.label", "Keep pursuing a goal across turns"),
      icon: "agent.chat",
      keywords: ["goal", "objective", "task"],
      action: { kind: "slash", command: goalCommand },
    });
  }

  for (const command of options.commands ?? []) {
    if (command.source !== "skill" && command.source !== "prompt") continue;
    const name = command.name.trim();
    if (!name) continue;
    rows.push({
      id: `add.skill.${name.toLowerCase()}`,
      section: "add",
      name: `/${name}`,
      description: command.description || description("composer.slashSkill", "Run this skill in the current chat"),
      icon: "terminal",
      keywords: [name, command.description],
      action: { kind: "slash", command },
    });
  }

  rows.push(
    {
      id: "add.mention",
      section: "add",
      name: label("composer.mention", "Mention"),
      description: description("composer.mention", "Reference a file or chat in the prompt"),
      icon: "composer.mention",
      keywords: ["@", "mention", "file", "chat"],
      action: { kind: "command", id: COMMANDS.mention },
    },
    {
      id: "add.commands",
      section: "add",
      name: label("composer.commands", "Commands"),
      description: description("composer.commands", "Choose a command advertised by this harness"),
      icon: "terminal",
      keywords: ["/", "slash", "commands"],
      action: { kind: "command", id: COMMANDS.commands },
    },
  );

  rows.push({
    id: "files.search",
    section: "files",
    name: label("files.search", "Files and chats"),
    description: description("files.search", "Search files or chats to attach as context"),
    icon: "search",
    keywords: ["files", "chats", "search", "context"],
    action: { kind: "command", id: COMMANDS.searchFiles },
  });

  const seen = new Set<string>();
  const extensions = [...(options.extensions ?? [])];
  const all = [...rows, ...extensions];
  return all.filter((entry) => {
    if (!entry.id || !entry.name.trim() || !entry.description.trim()) return false;
    const key = extensionKey(entry);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
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
