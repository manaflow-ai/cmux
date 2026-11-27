// Paths from a drop onto an empty state. A page sees a dropped item's path only when the drag
// carries it as text: `text/uri-list` file URLs (cmux's own file rows, most editors) or an
// absolute path in `text/plain`. WebKit hides the path of a Finder file (only its name), so the
// native host accepts those drags itself and opens them (diff-host.md "Empty state").

export interface DroppedItem {
  /** The absolute path, when the drag exposed one. */
  path: string | null;
  /** The display name (the file name even when the path is hidden). */
  name: string;
}

type TransferLike = {
  types?: readonly string[] | DOMStringList;
  getData(type: string): string;
  files?: ArrayLike<{ name: string; path?: unknown }> | null;
};

/** Whether a drag may carry something to open (files or text), for the drop highlight. */
export function dragMayOpen(transfer: { types?: readonly string[] | DOMStringList } | null): boolean {
  const types = Array.from(transfer?.types ?? []);
  return types.includes("Files") || types.includes("text/uri-list") || types.includes("text/plain");
}

/** The first dropped item, or null when the drop has nothing usable. */
export function droppedItem(transfer: TransferLike | null): DroppedItem | null {
  if (!transfer) return null;
  for (const line of safeData(transfer, "text/uri-list").split(/\r?\n/)) {
    const value = line.trim();
    if (!value || value.startsWith("#")) continue;
    const path = fileURLPath(value);
    if (path) return { path, name: baseOf(path) };
  }
  const text = safeData(transfer, "text/plain").trim();
  if (text.startsWith("/") && !text.includes("\n")) return { path: text, name: baseOf(text) };
  const fromURL = fileURLPath(text);
  if (fromURL) return { path: fromURL, name: baseOf(fromURL) };
  const file = transfer.files?.[0];
  if (file) {
    // Electron and some Chromium hosts expose the path on the File.
    const path = typeof file.path === "string" && file.path.startsWith("/") ? file.path : null;
    return { path, name: file.name };
  }
  return null;
}

function safeData(transfer: TransferLike, type: string): string {
  try {
    return transfer.getData(type) ?? "";
  } catch {
    return "";
  }
}

function fileURLPath(value: string): string | null {
  if (!/^file:\/\//i.test(value)) return null;
  try {
    const url = new URL(value);
    if (url.host && url.host !== "localhost") return null;
    const path = decodeURIComponent(url.pathname);
    return path.length > 1 ? path.replace(/\/+$/, "") : path;
  } catch {
    return null;
  }
}

function baseOf(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}
