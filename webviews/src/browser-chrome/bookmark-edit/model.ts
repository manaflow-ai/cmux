// The omnibar star's edit bubble (CmuxNextBookmarks BookmarkEditBubble hosts it): what the host
// pushes and what the page sends back. The folder choices are the home daemon's
// (`bookmarks.folders`, cmux-bookmarks-ops `lookup::folders`), in tree order under their root.

/** One folder the bookmark can live in, `depth` levels under its root (a root is 0). */
export type BookmarkEditFolder = { id: string; title: string; depth: number };

/** The host's state: the bookmark's name and folder, the choices, and the card's width in px. */
export type BookmarkEditState = {
  revision: number;
  isNew: boolean;
  title: string;
  folder: string;
  folders: BookmarkEditFolder[];
  width: number;
};

/** `edit` on each change (a dismiss saves what the bubble shows), then `done`, `remove` or `more`. */
export type BookmarkEditCommand = { type: "edit" | "done" | "remove" | "more"; title: string; folder: string };

/** The looks the gallery compares; the app draws `parity`. */
export type BookmarkEditLook = "parity" | "compact" | "roomy";
export const APP_BOOKMARK_EDIT_LOOK: BookmarkEditLook = "parity";

/** The bubble's width when the host sent none (half the palette's, as the native form had). */
export const DEFAULT_BUBBLE_WIDTH = 320;

function folder(raw: unknown): BookmarkEditFolder | null {
  if (!raw || typeof raw !== "object") return null;
  const value = raw as Record<string, unknown>;
  if (typeof value.id !== "string" || typeof value.title !== "string") return null;
  const depth = typeof value.depth === "number" && value.depth > 0 ? Math.floor(value.depth) : 0;
  return { id: value.id, title: value.title, depth };
}

/** The host's push, checked; null for anything that is not one. */
export function bookmarkEditState(raw: unknown): BookmarkEditState | null {
  if (!raw || typeof raw !== "object") return null;
  const value = raw as Record<string, unknown>;
  if (typeof value.title !== "string" || typeof value.folder !== "string") return null;
  const folders = Array.isArray(value.folders)
    ? value.folders.map(folder).filter((choice): choice is BookmarkEditFolder => choice !== null)
    : [];
  return {
    revision: typeof value.revision === "number" ? value.revision : 0,
    isNew: value.isNew === true,
    title: value.title,
    folder: value.folder,
    folders,
    width: typeof value.width === "number" && value.width > 0 ? value.width : DEFAULT_BUBBLE_WIDTH,
  };
}

/**
 * The folder menu's rows: each choice indented by its depth with no-break spaces (the native
 * menu's indent), plus the current folder when the daemon's list lacks it (a folder deleted while
 * the bubble opened), so the menu never shows an empty value.
 */
export function folderOptions(
  state: Pick<BookmarkEditState, "folders">,
  current: string,
): Array<{ value: string; label: string }> {
  const options = state.folders.map((choice) => ({
    value: choice.id,
    label: "    ".repeat(choice.depth) + choice.title,
  }));
  if (!options.some((option) => option.value === current)) options.push({ value: current, label: current });
  return options;
}

/**
 * The most folder rows the Folder menu draws at once. The app's popup host draws at most 1,000 rows
 * a level (CmuxNextDesign NativePopupModel+Validation), and a profile can hold more folders: the
 * menu shows the first ones in tree order and its search field finds any of them.
 */
export const FOLDER_MENU_LIMIT = 500;

/** One Folder menu row: an indented title, or a found folder with where it lives. */
export type FolderMenuOption = { value: string; label: string; description?: string };

/**
 * The Folder menu for `query`: with none, the first `limit` folders in tree order, indented, plus
 * the current one when it is past them; with one, the folders whose title holds every word (any
 * case), unindented, each with the folders it is in. `hidden` counts the matches left out.
 */
export function folderMenu(
  state: Pick<BookmarkEditState, "folders">,
  current: string,
  query: string,
  limit = FOLDER_MENU_LIMIT,
): { options: FolderMenuOption[]; hidden: number } {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) {
    const all = folderOptions(state, current);
    const options = all.slice(0, limit);
    if (!options.some((option) => option.value === current)) {
      const chosen = all.find((option) => option.value === current);
      if (chosen) options.push(chosen);
    }
    return { options, hidden: all.length - options.length };
  }
  const options: FolderMenuOption[] = [];
  let hidden = 0;
  // The titles of the folders above the one at each depth, as the list goes down in tree order.
  const above: string[] = [];
  for (const choice of state.folders) {
    above.length = choice.depth;
    const title = choice.title.toLowerCase();
    if (terms.every((term) => title.includes(term))) {
      if (options.length < limit) {
        const option: FolderMenuOption = { value: choice.id, label: choice.title };
        if (above.length > 0) option.description = above.join(" › ");
        options.push(option);
      } else hidden++;
    }
    above[choice.depth] = choice.title;
  }
  return { options, hidden };
}

/**
 * The name the bubble shows after a push: the host's when the person has not edited the one the
 * last push gave (a page title that arrived after the star), else the person's.
 */
export function adoptTitle(draft: string, previous: string | null, next: string): string {
  return previous === null || draft === previous ? next : draft;
}
