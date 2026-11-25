// The live gallery reads each first-party app's own preview fixtures (first-party-apps/<app>/preview,
// the scenes its preview/build.ts writes from the packed app), so a gallery entry imports them where
// they live instead of keeping a second copy under webviews. Only those folders are opened to the
// dev server, through Vite's own fs.allow: read-only (Vite serves files, it writes none), and
// confined, since Vite refuses any path outside an allowed folder, `..` and encoded traversal
// included. A folder is listed only when it is a real directory inside first-party-apps (no
// symlink out of the tree) under a plain app name.
import fs from "node:fs";
import path from "node:path";

const APP_NAME = /^[a-z0-9][a-z0-9._-]*$/i;

/** Every `first-party-apps/<app>/preview` folder under `repoRoot`, as resolved absolute paths. */
export function firstPartyPreviewDirs(repoRoot: string): string[] {
  let apps: string;
  try {
    apps = fs.realpathSync(path.join(repoRoot, "first-party-apps"));
  } catch {
    return [];
  }
  const out: string[] = [];
  for (const entry of fs.readdirSync(apps, { withFileTypes: true })) {
    if (!entry.isDirectory() || !APP_NAME.test(entry.name) || entry.name.includes("..")) continue;
    const preview = path.join(apps, entry.name, "preview");
    let stat: fs.Stats;
    try {
      stat = fs.lstatSync(preview);
    } catch {
      continue;
    }
    if (!stat.isDirectory() || stat.isSymbolicLink()) continue;
    const real = fs.realpathSync(preview);
    if (path.dirname(path.dirname(real)) !== apps) continue;
    out.push(real);
  }
  return out.sort();
}
