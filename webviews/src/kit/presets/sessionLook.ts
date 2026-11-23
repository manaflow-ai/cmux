// A session list's look as the theme-file keys the native sidebar reads (cmux#45143's
// minimal-sessions theme file): the same names, so a look written for the app's
// sidebar describes a web page built from the kit too. Only the keys a kit row draws are here.

export type SessionState = "idle" | "working" | "waiting" | "permission" | "done" | "error";

export interface SessionLook {
  "sidebar.density": "compact" | "comfortable";
  /** Where the status mark sits: before the name, or in the trailing column. */
  "sidebar.workspaceRow.statusPlacement": "leading" | "trailing";
  /** A mark for done too; off, only working and what needs the person (waiting, permission, error) show. */
  "sidebar.detailedStatusIcons": boolean;
  "sidebar.workspaceRow.icon": boolean;
  "sidebar.workspaceRow.directory": boolean;
  "sidebar.workspaceRow.branch": boolean;
  "sidebar.workspaceRow.tabCount": boolean;
  "sidebar.workspaceRow.lastActivity": boolean;
}

/** The app's default row: icon, status at the end, the folder and branch on a second line. */
export const DEFAULT_SESSION_LOOK: SessionLook = {
  "sidebar.density": "comfortable",
  "sidebar.workspaceRow.statusPlacement": "trailing",
  "sidebar.detailedStatusIcons": false,
  "sidebar.workspaceRow.icon": true,
  "sidebar.workspaceRow.directory": true,
  "sidebar.workspaceRow.branch": true,
  "sidebar.workspaceRow.tabCount": true,
  "sidebar.workspaceRow.lastActivity": false,
};

/** Minimal sessions (minimal-sessions.json): one line per session, its status first, then its name. */
export const MINIMAL_SESSIONS_LOOK: SessionLook = {
  "sidebar.density": "compact",
  "sidebar.workspaceRow.statusPlacement": "leading",
  "sidebar.detailedStatusIcons": true,
  "sidebar.workspaceRow.icon": false,
  "sidebar.workspaceRow.directory": false,
  "sidebar.workspaceRow.branch": false,
  "sidebar.workspaceRow.tabCount": false,
  "sidebar.workspaceRow.lastActivity": false,
};

/** A theme file's keys over a base look; keys the kit does not draw, and wrong types, are ignored. */
export function sessionLook(themeFile: Record<string, unknown>, base: SessionLook = DEFAULT_SESSION_LOOK): SessionLook {
  const look = { ...base };
  const pick = <K extends keyof SessionLook>(key: K, ok: (value: unknown) => boolean) => {
    if (ok(themeFile[key])) look[key] = themeFile[key] as SessionLook[K];
  };
  pick("sidebar.density", (v) => v === "compact" || v === "comfortable");
  pick("sidebar.workspaceRow.statusPlacement", (v) => v === "leading" || v === "trailing");
  for (const key of [
    "sidebar.detailedStatusIcons",
    "sidebar.workspaceRow.icon",
    "sidebar.workspaceRow.directory",
    "sidebar.workspaceRow.branch",
    "sidebar.workspaceRow.tabCount",
    "sidebar.workspaceRow.lastActivity",
  ] as const)
    pick(key, (v) => typeof v === "boolean");
  return look;
}
