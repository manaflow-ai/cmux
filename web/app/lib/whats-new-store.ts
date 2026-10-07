import fs from "node:fs";
import path from "node:path";
import { WhatsNewStore } from "./whats-new";

// The documents tools/sync-whats-new.ts copied into public/whats-new/ before
// the build; a build that skipped the sync (dev, test servers) reads the
// repository's whats-new/ directly. Every version page is prerendered from them.
const candidates = [
  path.resolve(process.cwd(), "public", "whats-new"),
  path.resolve(process.cwd(), "..", "whats-new"),
];

function readFiles(): { name: string; text: string }[] {
  for (const directory of candidates) {
    if (!fs.existsSync(directory)) continue;
    const names = fs.readdirSync(directory).filter((name) => name.endsWith(".json"));
    if (names.length === 0) continue;
    return names.map((name) => ({ name, text: fs.readFileSync(path.join(directory, name), "utf-8") }));
  }
  return [];
}

export const whatsNewStore = new WhatsNewStore(readFiles());
