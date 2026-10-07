import fs from "node:fs";
import path from "node:path";
import { WhatsNewStore } from "./whats-new";

// The documents tools/sync-whats-new.ts copied into public/whats-new/ (read at
// build time: every version page is prerendered from these files).
const directory = path.resolve(process.cwd(), "public", "whats-new");

function readFiles(): { name: string; text: string }[] {
  if (!fs.existsSync(directory)) return [];
  return fs
    .readdirSync(directory)
    .filter((name) => name.endsWith(".json"))
    .map((name) => ({ name, text: fs.readFileSync(path.join(directory, name), "utf-8") }));
}

export const whatsNewStore = new WhatsNewStore(readFiles());
