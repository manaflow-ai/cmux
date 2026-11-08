// The Import Cookies card's wire (CmuxNextBrowser BrowserCookieImportCard through CmuxNextPages
// BrowserChromeWebHost): the host pushes what the card says, localized, and the browser's icon;
// the page sends the person's answer and the height its content needs.

/** What the card shows. The host localizes every line; the page adds no text of its own. */
export type CookieImportCardModel = {
  /** "Import cookies from Google Chrome". */
  title: string;
  /** "Stay signed in to your sites. Nothing leaves this Mac." */
  detail: string;
  importTitle: string;
  notNowTitle: string;
  /** Don't Show Again; absent or null shows only Not Now and Import. */
  neverTitle?: string | null;
  /** The browser's app icon as a data URL (PNG); absent shows no icon. */
  icon?: string | null;
  /** "Keep in sync": a checkbox under the detail when the browser's cookies can be kept in sync
   * after the import (a Chromium browser); absent or null shows none. */
  keepInSyncTitle?: string | null;
  /** The checkbox's first state (`browser.import.cookieSync`, on by default). */
  keepInSync?: boolean;
};

/** The person's answer; every answer closes the card. */
export type CookieImportChoice = "import" | "notNow" | "never";

/** A page command, as the host reads it (`BrowserCookieImportCard.received`). Import carries the
 * Keep in sync answer when the card showed the checkbox. */
export type CookieImportCommand = { type: CookieImportChoice; keepInSync?: boolean };

/**
 * The card's looks (gallery). The app draws `split`.
 * - `split`: icon and two lines, then one row: Don't Show Again as a quiet link under the text
 *   column, Not Now and Import at the end, the same height.
 * - `trailing`: the same header; all three answers grouped at the end of the row.
 * - `inline`: one row: icon, two lines, the two buttons beside them; Don't Show Again as a link
 *   in the detail line.
 */
export type CookieImportLook = "split" | "trailing" | "inline";

export const COOKIE_IMPORT_LOOKS: readonly CookieImportLook[] = ["split", "trailing", "inline"];

/** The look the app draws (picked in the gallery: see design/browser-chrome.md). */
export const APP_COOKIE_IMPORT_LOOK: CookieImportLook = "split";

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
  const keep = text("keepInSyncTitle");
  return {
    title,
    detail: text("detail"),
    importTitle,
    notNowTitle,
    neverTitle: never || null,
    // Only an inline image: the page loads nothing from elsewhere.
    icon: icon.startsWith("data:image/") ? icon : null,
    keepInSyncTitle: keep || null,
    keepInSync: value.keepInSync !== false,
  };
}
