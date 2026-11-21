// The Import Cookies card's wire (CmuxNextBrowser BrowserCookieImportCard through CmuxNextPages
// BrowserChromeWebHost): the host pushes what the card says, localized, and the browser's icon;
// the page sends the person's answer and the height its content needs.

/** What the card shows. The host localizes every line; the page adds no text of its own. */
export type CookieImportCardModel = {
  /** "Import cookies from Google Chrome": the card's one line. */
  title: string;
  importTitle: string;
  notNowTitle: string;
  /** Don't Show Again; absent or null shows only Not Now and Import. */
  neverTitle?: string | null;
  /** The browser's app icon as a data URL (PNG); absent shows no icon. */
  icon?: string | null;
};

/** The person's answer; every answer closes the card. */
export type CookieImportChoice = "import" | "notNow" | "never";

/** A page command, as the host reads it (`BrowserCookieImportCard.received`). */
export type CookieImportCommand = { type: CookieImportChoice };

/**
 * The card's looks (gallery). The app draws `toast`.
 * - `toast`: one row in the toast's grammar: icon, the line, Don't Show Again quiet and Import bold
 *   as clear text, the close button as Not Now.
 * - `buttons`: one row: icon, the line, Don't Show Again as a ghost button, Not Now and Import as
 *   compact buttons.
 * - `stacked`: icon and the line, then a row of the three answers under it.
 */
export type CookieImportLook = "toast" | "buttons" | "stacked";

export const COOKIE_IMPORT_LOOKS: readonly CookieImportLook[] = ["toast", "buttons", "stacked"];

/** The look the app draws (picked in the gallery: see design/browser-chrome.md). */
export const APP_COOKIE_IMPORT_LOOK: CookieImportLook = "toast";

/** Reads a pushed state into a model: every line a string, the optional ones dropped when blank. */
export function cookieImportModel(state: unknown): CookieImportCardModel | null {
  if (!state || typeof state !== "object") return null;
  const value = state as Record<string, unknown>;
  const text = (key: string) => (typeof value[key] === "string" ? (value[key] as string) : "");
  const title = text("title");
  const importTitle = text("importTitle");
  const notNowTitle = text("notNowTitle");
  if (!title || !importTitle || !notNowTitle) return null;
  const never = text("neverTitle");
  const icon = text("icon");
  return {
    title,
    importTitle,
    notNowTitle,
    neverTitle: never || null,
    // Only an inline image: the page loads nothing from elsewhere.
    icon: icon.startsWith("data:image/") ? icon : null,
  };
}
