// The Page Info bubble's data and commands: plain mirrors of the Swift model (CmuxNextBrowserCore
// PageInfoCommand / SitePermission / SiteData, CmuxNextBrowser PageInfoSite / PageInfoModel). The
// host fills the model; every control sends one `PageInfoCommand`, nothing changes state here.

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

export type SitePermissionState = {
  kind: SitePermissionKind;
  /** The effective value: the user's decision, else the default. */
  setting: SitePermissionSetting;
  /** No decision stored. */
  isDefault: boolean;
  /** The page uses it now (camera or microphone capturing). */
  isInUse?: boolean;
};

/** The cookies subpage's numbers (`SiteDataSummary`). */
export type SiteDataSummary = {
  firstPartyCookies: number;
  siteCount: number;
  thirdPartyPolicy: "allowed" | "blocked";
};

export type PageInfoPage =
  | { type: "main" }
  | { type: "security" }
  | { type: "cookies" }
  | { type: "permission"; kind: SitePermissionKind };

/** Everything the bubble can do (`PageInfoCommand`); each is one registry action or a move inside it. */
export type PageInfoCommand =
  | { type: "show"; page: PageInfoPage }
  | { type: "showCertificate" }
  | { type: "setPermission"; kind: SitePermissionKind; setting: SitePermissionSetting }
  | { type: "resetPermissions" }
  | { type: "siteSettings" }
  | { type: "manageSiteData" }
  | { type: "deleteSiteData"; domain: string | null }
  | { type: "aboutThisPage" }
  | { type: "reenableCertificateWarnings" }
  | { type: "reload" }
  | { type: "close" };

/** What the bubble shows (`PageInfoModel`), resolved by the host. */
export type PageInfoModel = {
  site: PageInfoSite;
  page: PageInfoPage;
  /** The rows of the main page, in Chromium's order. */
  permissions: SitePermissionState[];
  /** null while loading. */
  siteData: SiteDataSummary | null;
  /** The security page's certificate row; null hides it (http, or an empty chain). */
  certificate: { valid: boolean; issuer?: string } | null;
  /** The engine's reason the certificate failed, under the details. */
  certificateFailure?: string;
  /** The user proceeded past this site's certificate warning. */
  certificateWarningsOff?: boolean;
  /** What "Turn on warnings" covers on this engine. */
  certificateWarningScope?: "site" | "profile";
  /** A change needs a reload to apply. */
  needsReload?: boolean;
  /** Public web pages offer "About this page". */
  showsAboutThisPage?: boolean;
};

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
const NO_ASK = new Set<SitePermissionKind>([...ALLOW_BY_DEFAULT, ...BLOCK_BY_DEFAULT]);
const NO_ALLOW = new Set<SitePermissionKind>(["usb", "serial", "hid", "bluetooth", "fileEditing"]);

export function defaultSetting(kind: SitePermissionKind): SitePermissionSetting {
  if (ALLOW_BY_DEFAULT.has(kind)) return "allow";
  if (BLOCK_BY_DEFAULT.has(kind)) return "block";
  return "ask";
}

/** The choices the permission subpage offers. */
export function choices(kind: SitePermissionKind): SitePermissionSetting[] {
  if (NO_ASK.has(kind)) return ["allow", "block"];
  return NO_ALLOW.has(kind) ? ["ask", "block"] : ["ask", "allow", "block"];
}

/** What the row's toggle stores when switched on. */
export function enabledSetting(kind: SitePermissionKind): SitePermissionSetting {
  return NO_ALLOW.has(kind) ? "ask" : "allow";
}

/** The row's toggle: on when allowed (guard kinds: when not blocked). */
export function isOn(state: SitePermissionState): boolean {
  return NO_ALLOW.has(state.kind) ? state.setting !== "block" : state.setting === "allow";
}

/** Permissions the user changed from their default ("Reset permissions"). */
export function resettableCount(permissions: readonly SitePermissionState[]): number {
  return permissions.filter((state) => !state.isDefault).length;
}

export function isDanger(connection: PageInfoConnection): boolean {
  return connection === "certificateError" || connection === "dangerous";
}

// MARK: Icons (pack names of the SF Symbols PageInfoPages draws)

export function connectionIcon(connection: PageInfoConnection): string {
  switch (connection) {
    case "secure":
      return "security.lock";
    case "insecure":
    case "mixedContent":
      return "browser.omnibox.notsecure";
    case "certificateError":
    case "dangerous":
      return "browser.omnibox.dangerous";
  }
}

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

export function identityIcon(kind: PageInfoSiteKind): string {
  switch (kind) {
    case "file":
      return "file";
    case "extensionPage":
      return "browser.toolbar.extensions";
    default:
      return "terminal";
  }
}

/**
 * Splits a site name for middle truncation: the head may be cut, the tail always shows. A host
 * keeps its registrable domain and port in the tail (the last two labels, or three when the
 * second-level label is a short public one such as `co.uk`); any other name keeps its last 16
 * characters.
 */
export function splitSiteName(name: string): [head: string, tail: string] {
  const port = /:\d+$/.exec(name)?.[0] ?? "";
  const host = port ? name.slice(0, -port.length) : name;
  if (/^[^\s/]+\.[^\s/.]+$/.test(host)) {
    const labels = host.split(".");
    const keep = labels.length > 2 && labels[labels.length - 2].length <= 3 ? 3 : 2;
    if (labels.length <= keep) return ["", name];
    return [labels.slice(0, -keep).join(".") + ".", labels.slice(-keep).join(".") + port];
  }
  const cut = Math.max(0, name.length - 16);
  return [name.slice(0, cut), name.slice(cut)];
}
