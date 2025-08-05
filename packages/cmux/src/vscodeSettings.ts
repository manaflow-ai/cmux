import { existsSync, promises as fs } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { parse as parseJsonc } from "jsonc-parser";

export type EditorType = "vscode" | "cursor" | "windsurf";

export interface EditorConfig {
  type: EditorType;
  displayName: string;
  appName: string;
  appNameLower: string;
  settingsPath: string;
  extensionsPath: string;
}

export const EDITOR_CONFIGS: Record<EditorType, EditorConfig> = {
  vscode: {
    type: "vscode",
    displayName: "VS Code",
    appName: "Code",
    appNameLower: "vscode",
    settingsPath: path.join(homedir(), "Library", "Application Support", "Code", "User"),
    extensionsPath: path.join(homedir(), ".vscode", "extensions"),
  },
  cursor: {
    type: "cursor",
    displayName: "Cursor",
    appName: "Cursor",
    appNameLower: "cursor",
    settingsPath: path.join(homedir(), "Library", "Application Support", "Cursor", "User"),
    extensionsPath: path.join(homedir(), ".cursor", "extensions"),
  },
  windsurf: {
    type: "windsurf",
    displayName: "Windsurf",
    appName: "Windsurf",
    appNameLower: "windsurf",
    settingsPath: path.join(homedir(), "Library", "Application Support", "Windsurf", "User"),
    extensionsPath: path.join(homedir(), ".windsurf", "extensions"),
  },
};

export async function detectInstalledEditors(): Promise<EditorConfig[]> {
  const installedEditors: EditorConfig[] = [];

  for (const config of Object.values(EDITOR_CONFIGS)) {
    if (existsSync(config.settingsPath) || existsSync(config.extensionsPath)) {
      installedEditors.push(config);
    }
  }

  return installedEditors;
}

export interface VSCodeSettings {
  settings?: Record<string, any>;
  keybindings?: any[];
  extensions?: string[];
  snippets?: Record<string, any>;
}

export async function readEditorSettings(editor: EditorConfig): Promise<VSCodeSettings> {
  const result: VSCodeSettings = {};

  try {
    const settingsPath = path.join(editor.settingsPath, "settings.json");
    if (existsSync(settingsPath)) {
      const content = await fs.readFile(settingsPath, "utf-8");
      result.settings = parseJsonc(content);
    }
  } catch (error) {
    console.error(`Failed to read settings for ${editor.displayName}:`, error);
  }

  try {
    const keybindingsPath = path.join(editor.settingsPath, "keybindings.json");
    if (existsSync(keybindingsPath)) {
      const content = await fs.readFile(keybindingsPath, "utf-8");
      result.keybindings = parseJsonc(content);
    }
  } catch (error) {
    console.error(`Failed to read keybindings for ${editor.displayName}:`, error);
  }

  try {
    if (existsSync(editor.extensionsPath)) {
      const extensionDirs = await fs.readdir(editor.extensionsPath);
      result.extensions = extensionDirs.filter(dir => !dir.startsWith("."));
    }
  } catch (error) {
    console.error(`Failed to read extensions for ${editor.displayName}:`, error);
  }

  try {
    const snippetsDir = path.join(editor.settingsPath, "snippets");
    if (existsSync(snippetsDir)) {
      const snippetFiles = await fs.readdir(snippetsDir);
      result.snippets = {};
      
      for (const file of snippetFiles) {
        if (file.endsWith(".json")) {
          const content = await fs.readFile(path.join(snippetsDir, file), "utf-8");
          result.snippets[file] = parseJsonc(content);
        }
      }
    }
  } catch (error) {
    console.error(`Failed to read snippets for ${editor.displayName}:`, error);
  }

  return result;
}

export async function saveSettingsForRemote(
  settings: VSCodeSettings,
  targetDir: string
): Promise<void> {
  await fs.mkdir(targetDir, { recursive: true });

  if (settings.settings) {
    await fs.writeFile(
      path.join(targetDir, "settings.json"),
      JSON.stringify(settings.settings, null, 2)
    );
  }

  if (settings.keybindings) {
    await fs.writeFile(
      path.join(targetDir, "keybindings.json"),
      JSON.stringify(settings.keybindings, null, 2)
    );
  }

  if (settings.extensions && settings.extensions.length > 0) {
    await fs.writeFile(
      path.join(targetDir, "extensions.txt"),
      settings.extensions.join("\n")
    );
  }

  if (settings.snippets && Object.keys(settings.snippets).length > 0) {
    const snippetsDir = path.join(targetDir, "snippets");
    await fs.mkdir(snippetsDir, { recursive: true });
    
    for (const [filename, content] of Object.entries(settings.snippets)) {
      await fs.writeFile(
        path.join(snippetsDir, filename),
        JSON.stringify(content, null, 2)
      );
    }
  }
}