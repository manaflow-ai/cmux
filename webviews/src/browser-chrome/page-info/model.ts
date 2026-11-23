// What Page Info's windows share with the Swift model (CmuxNextBrowserCore SitePermission,
// CmuxNextBrowser PageInfoSite): the site, the permission kinds and settings, each kind's default
// and its icon. The bubble itself is AppKit (CmuxNextBrowser PageInfo/UI).

/** Chromium `security_state` as Page Info words it (`PageInfoConnection`). */
export type PageInfoConnection = "secure" | "insecure" | "mixedContent" | "certificateError" | "dangerous";

/** What kind of page the bubble describes (`PageInfoSiteKind`; `web` carries its connection). */
export type PageInfoSiteKind = "web" | "file" | "internalPage" | "extensionPage" | "viewSource" | "devTools";

export type PageInfoSite = {
  kind: PageInfoSiteKind;
  /** Set for `web`. */
  connection?: PageInfoConnection;
  /** The bubble title: host[:port] for web pages, the path for files (`PageInfoSite.displayName`). */
  displayName: string;
};

export const SITE_PERMISSION_KINDS = [
  "location",
  "camera",
  "microphone",
  "notifications",
  "javascript",
  "images",
  "popups",
  "sound",
  "automaticDownloads",
  "midi",
  "usb",
  "serial",
  "hid",
  "clipboard",
  "sensors",
  "bluetooth",
  "fileEditing",
  "windowManagement",
  "localFonts",
  "backgroundSync",
  "autoPictureInPicture",
  "thirdPartySignIn",
  "insecureContent",
] as const;

export type SitePermissionKind = (typeof SITE_PERMISSION_KINDS)[number];
export type SitePermissionSetting = "ask" | "allow" | "block";

// MARK: Rules (SitePermissionKind)

const ALLOW_BY_DEFAULT = new Set<SitePermissionKind>([
  "javascript",
  "images",
  "sound",
  "sensors",
  "backgroundSync",
  "thirdPartySignIn",
]);
const BLOCK_BY_DEFAULT = new Set<SitePermissionKind>(["popups", "insecureContent"]);

export function defaultSetting(kind: SitePermissionKind): SitePermissionSetting {
  if (ALLOW_BY_DEFAULT.has(kind)) return "allow";
  if (BLOCK_BY_DEFAULT.has(kind)) return "block";
  return "ask";
}

// MARK: Icons (pack names)

const BLOCKED_ICONS: Partial<Record<SitePermissionKind, string>> = {
  location: "site.permission.location.blocked",
  camera: "site.permission.camera.blocked",
  microphone: "site.permission.microphone.blocked",
  notifications: "site.permission.notifications.blocked",
  sound: "site.permission.sound.blocked",
  insecureContent: "site.permission.insecurecontent.blocked",
};

/** A blocked permission gets its crossed-out icon. */
export function permissionIcon(kind: SitePermissionKind, blocked: boolean): string {
  const crossed = blocked ? BLOCKED_ICONS[kind] : undefined;
  if (crossed) return crossed;
  if (kind === "insecureContent") return "security.insecure";
  return `site.permission.${kind.toLowerCase()}`;
}
