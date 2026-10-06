// LAUNCH-NO-TCC-PROMPTS: which folders a warm (an agent started before any person asks) may use.
// An agent starts with its cwd in the folder and may read it at once, so a warm never targets the
// home folder, "/", or a folder in a location macOS guards with a privacy prompt. The daemon refuses
// the same folders after resolving symlinks; this check is by spelling, before the request goes out.

/// The locations macOS guards, relative to the home folder.
const GUARDED_IN_HOME = [
  "Desktop",
  "Documents",
  "Downloads",
  "Pictures",
  "Music",
  "Movies",
  "Library/Mobile Documents",
  "Library/CloudStorage",
  "Library/Containers",
  "Library/Group Containers",
  "Library/Mail",
  "Library/Messages",
  "Library/Safari",
  "Library/Calendars",
];

/// Guarded locations outside any home folder: other and network volumes.
const GUARDED_ROOTS = ["/Volumes", "/Network", "/net"];

/// The home folder `path` is in (`/Users/<name>` or `/home/<name>`), if any.
export function homeOf(path: string): string | undefined {
  const match = /^\/(Users|home)\/[^/]+/i.exec(path);
  return match?.[0];
}

/// True when an agent may be started in `cwd` without a person asking.
export function isWarmableCwd(cwd: string): boolean {
  const path = cwd.replace(/\/+$/, "");
  if (!path.startsWith("/") || path === "" || path.split("/").includes("..")) return false;
  const folded = path.toLowerCase();
  const under = (root: string) => folded === root.toLowerCase() || folded.startsWith(`${root.toLowerCase()}/`);
  if (GUARDED_ROOTS.some(under)) return false;
  const home = homeOf(path);
  if (!home) return true;
  if (folded === home.toLowerCase()) return false;
  return !GUARDED_IN_HOME.some((relative) => under(`${home}/${relative}`));
}
