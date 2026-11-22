// Dev server only: reads the user's diff viewer languages folder the way the app host does and
// returns the `DiffLanguagePack` the page installs (src/diff-languages/pack.ts has the format).
// The host stays dumb on purpose: it sends each JSON file as text and the page validates, so
// Swift, the Rust pane protocol and this file all deliver the same thing.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/// Per-file and whole-folder caps, so a stray large file cannot stall the page.
export const LANGUAGE_FILE_LIMIT = 4 * 1024 * 1024;
export const LANGUAGE_PACK_LIMIT = 32 * 1024 * 1024;

/// `<dir of cmux.json>/diff/languages`: `CMUX_NEXT_CONFIG_FILE` moves cmux.json and this folder
/// with it, as it does `agent-pane/`.
export function diffLanguagesDirectory(env: NodeJS.ProcessEnv = process.env, home = os.homedir()): string {
  const override = env.CMUX_NEXT_CONFIG_FILE?.trim();
  const configFile = override ? override : path.join(home, ".config", "cmux", "cmux.json");
  return path.join(path.dirname(configFile), "diff", "languages");
}

/// Every `*.json` file directly in `directory` (and one level of subfolders), or an empty pack
/// when the folder does not exist. Symlinks are followed only to regular files.
export function readDiffLanguagePack(directory: string): { files: Array<{ path: string; text: string }> } {
  const files: Array<{ path: string; text: string }> = [];
  let total = 0;
  const visit = (relative: string, depth: number) => {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(path.join(directory, relative), { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.name.startsWith(".")) continue;
      const child = relative ? `${relative}/${entry.name}` : entry.name;
      const absolute = path.join(directory, child);
      let stat: fs.Stats;
      try {
        stat = fs.statSync(absolute);
      } catch {
        continue;
      }
      if (stat.isDirectory()) {
        if (depth === 0) visit(child, depth + 1);
        continue;
      }
      if (!stat.isFile() || !entry.name.endsWith(".json")) continue;
      if (stat.size > LANGUAGE_FILE_LIMIT || total + stat.size > LANGUAGE_PACK_LIMIT) continue;
      try {
        files.push({ path: child, text: fs.readFileSync(absolute, "utf8") });
        total += stat.size;
      } catch {
        // Unreadable files are skipped; the rest still apply.
      }
    }
  };
  visit("", 0);
  return { files };
}
