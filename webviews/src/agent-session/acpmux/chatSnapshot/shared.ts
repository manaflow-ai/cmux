// What a chat's page last showed, as markup, drawn in the next document's first frame before the
// bundle runs (Leo, 2026-11-07: "we need to make these after-restart things load a lot faster";
// "is there a paradigm here where we can think of it like we are, in effect, operating a kind of
// website"). The page writes it (capture.ts, writer.ts), the host keeps one per chat on disk
// (`chat.snapshot.put` / `chat.snapshot.get`, AgentPaneChatSnapshots.swift) and serves it to the
// next document as `__snapshot/chat.js`, and the page's first classic script paints it (boot.ts)
// in a shadow root over the live page, which takes over in one frame once it drew the chat
// (live.ts). Shared by the boot script and the bundle, so it imports nothing.

/// The shape's version: a snapshot of another version is never drawn.
export const SNAPSHOT_VERSION = 1;
/// The most markup one snapshot carries, in UTF-16 units (`String.length`). The visible window only:
/// the shell and the transcript rows in view, so this does not grow with the transcript.
export const SNAPSHOT_MAX_CHARS = 256 * 1024;
/// The global the host's `__snapshot/chat.js` sets: the stored snapshot, or null.
export const SNAPSHOT_GLOBAL = "__cmuxChatSnapshot";
/// The global the host's `__snapshot/chat.js` sets: the key of the theme the page gets now (the
/// host's `theme` event `key`, AgentPageEvent.swift).
export const SNAPSHOT_THEME_GLOBAL = "__cmuxChatSnapshotTheme";
/// The global the boot script sets when it drew nothing: why (live.ts `chatSnapshotReport`).
export const SNAPSHOT_MISS_GLOBAL = "__cmuxChatSnapshotMiss";
/// The global the boot script sets once it drew one: when, in `performance.now()` time.
export const SNAPSHOT_SHOWN_GLOBAL = "__cmuxChatSnapshotShown";
/// The function the boot script defines and the host's `__snapshot/chat.js` calls once it set the
/// globals: that script loads `async`, so the document and the bundle never wait for the host's
/// answer, and the copy draws whenever it comes, before or after the bundle starts (boot.ts).
export const SNAPSHOT_BOOT_GLOBAL = "__cmuxChatSnapshotBoot";
/// The live page's side, which the boot script reads (live.ts): `drawn` once the page drew the chat
/// itself (a copy that comes later draws nothing), and `painted`, called when a copy draws after the
/// bundle started.
export const SNAPSHOT_LIVE_GLOBAL = "__cmuxChatSnapshotLive";
export type SnapshotLive = { drawn?: boolean; painted?: () => void };
/// The element the copy is drawn in (its shadow root holds the copy).
export const SNAPSHOT_HOST_TAG = "cmux-chat-snapshot";
/// The copy's stand-ins for `<html>` and `<body>`, which a shadow tree cannot hold: the page's own
/// rules for those are rewritten to these, with the same specificity.
export const SNAPSHOT_HTML_TAG = "cmux-snapshot-html";
export const SNAPSHOT_BODY_TAG = "cmux-snapshot-body";
/// `:root` in the copy's rules (a class, as `:root` is a pseudo-class: the same specificity).
export const SNAPSHOT_ROOT_CLASS = "cmux-snapshot-root";
/// An element of the copy that was scrolled: `top,left` in CSS pixels.
export const SNAPSHOT_SCROLL_ATTRIBUTE = "data-cmux-snapshot-scroll";
/// A shadow root's adopted sheets, by index in the snapshot's `sheets`.
export const SNAPSHOT_SHEETS_ATTRIBUTE = "data-cmux-snapshot-sheets";
/// The page's stylesheet (build-agent-pane-web.sh).
export const PAGE_STYLE_ID = "cmux-pane-styles";

export type SnapshotAttributes = Record<string, string>;

/// One chat's snapshot as the page writes it and the host stores it (opaque to the host).
export type ChatSnapshot = {
  v: number;
  /// `<main id="root">` as it was drawn, rows out of view left out.
  html: string;
  /// The viewport it was drawn at, in CSS pixels: markup laid out for another size is never drawn.
  width: number;
  height: number;
  /// `<html>`'s and `<body>`'s attributes then (the theme's variables, the look's data attributes).
  root: SnapshotAttributes;
  body: SnapshotAttributes;
  /// Adopted stylesheets of shadow roots in the markup, once each.
  sheets: string[];
  /// The page's other sheets then (the person's theme.css, sheets a chunk added), in order.
  styles: string[];
  /// The key of the theme it was drawn in (the host's `theme` event `key`).
  theme: string;
  /// When it was written (`Date.now()`).
  savedAt: number;
};

/// Whether `value` is a snapshot this version draws.
export function isChatSnapshot(value: unknown): value is ChatSnapshot {
  const snapshot = value as Partial<ChatSnapshot> | null | undefined;
  return (
    typeof snapshot === "object" &&
    snapshot !== null &&
    snapshot.v === SNAPSHOT_VERSION &&
    typeof snapshot.html === "string" &&
    snapshot.html.length > 0 &&
    snapshot.html.length <= SNAPSHOT_MAX_CHARS &&
    typeof snapshot.width === "number" &&
    typeof snapshot.height === "number" &&
    typeof snapshot.root === "object" &&
    snapshot.root !== null &&
    typeof snapshot.body === "object" &&
    snapshot.body !== null &&
    Array.isArray(snapshot.sheets) &&
    Array.isArray(snapshot.styles) &&
    typeof snapshot.theme === "string" &&
    snapshot.theme.length > 0
  );
}

/// An element's attributes as a record.
export function attributesOf(element: Element): SnapshotAttributes {
  const out: SnapshotAttributes = {};
  for (const attribute of Array.from(element.attributes)) out[attribute.name] = attribute.value;
  return out;
}

/// How much taller or shorter the viewport may be than the one a copy was drawn at. The copy is the
/// page's own markup under its own rules, so it lays out at the new height as the live page will
/// (the composer stays at the bottom, the transcript keeps its scroll offset); a window restored a
/// tab row shorter than it was written (28 px on the fleet's chat-open restore) drew nothing before.
/// Rows are placed for the width, so the width must match.
export const SNAPSHOT_HEIGHT_SLACK = 64;

/// Whether `snapshot` was drawn for the document as it is now: the same width and a height within
/// ``SNAPSHOT_HEIGHT_SLACK``, and the theme the host gives the page now (its key, which the host's
/// `__snapshot/chat.js` set). Colors, fonts and the look all come with the theme; rows laid out for
/// another width would draw at the wrong places.
export function fitsDocument(snapshot: ChatSnapshot, doc: Document): boolean {
  return misfit(snapshot, doc) === undefined;
}

/// Why `snapshot` does not fit `doc` (``fitsDocument``), or undefined when it does.
export function misfit(snapshot: ChatSnapshot, doc: Document): string | undefined {
  const view = doc.defaultView;
  if (!view) return "no-window";
  const size = `${Math.round(view.innerWidth)}x${Math.round(view.innerHeight)}`;
  const drawn = `${Math.round(snapshot.width)}x${Math.round(snapshot.height)}`;
  const widthFits = Math.round(view.innerWidth) === Math.round(snapshot.width);
  const heightFits = Math.abs(view.innerHeight - snapshot.height) <= SNAPSHOT_HEIGHT_SLACK;
  // l10n-allow: a diagnostic code for the page's debug record (layoutWatch.ts), never shown in the pane.
  if (!widthFits || !heightFits) return `size ${size}, drawn at ${drawn}`;
  if ((view as unknown as Record<string, unknown>)[SNAPSHOT_THEME_GLOBAL] !== snapshot.theme) return "theme";
  return undefined;
}
