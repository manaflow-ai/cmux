import type { Translate } from "./i18n";
import type { SlashCommand } from "./slashCommands";

/**
 * The command palette rows exposed by the composer's + menu.
 *
 * The registry owns labels, descriptions, icons and stable action ids. Hosts provide the live
 * rows for tools, sessions and tabs; the composer routes these stable ids to its existing handlers
 * rather than adding a second implementation of each action.
 */
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
  /** The commands advertised by the harness; skills and prompts become Add rows. */
  commands?: readonly SlashCommand[];
  /** The pane translator keeps existing composer actions localized. */
  translate?: Translate;
  /** A harness can omit screenshots/window capture when its capture bridge is unavailable. */
  canCapture?: boolean;
  /** Whether this surface can select a project/cwd before sending. */
  canChooseProject?: boolean;
  /** Whether the composer can change its run mode from this menu. */
  planMode?: { id: string; name: string; description: string };
  /** Live rows from the command-palette registry for tools, sessions, tabs and file search. */
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

/**
 * Builds the + menu in display order. Empty sections are omitted by consumers, while the returned
 * section field keeps rows interoperable with the native command-palette section ordering.
 */
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

/** Group entries without changing the registry's explicit section and row order. */
export function composerPlusSections(
  entries: readonly ComposerPlusEntry[],
): Map<ComposerPlusSection, ComposerPlusEntry[]> {
  const sections = new Map<ComposerPlusSection, ComposerPlusEntry[]>(
    COMPOSER_PLUS_SECTIONS.map((section) => [section, []]),
  );
  for (const entry of entries) sections.get(entry.section)?.push(entry);
  return sections;
}

/** The + menu is an instant command surface; it must never fade in. */
export const COMPOSER_PLUS_MOTION = "none" as const;

/** A single dispatch path for a + row. The composer supplies its existing action callbacks. */
export function runComposerPlusAction(
  action: ComposerPlusAction,
  handlers: {
    command(id: string, modeId?: string): void;
    /** Dispatches a host-provided command-palette ID, such as palette.openBrowser. */
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
