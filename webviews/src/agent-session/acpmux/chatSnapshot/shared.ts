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
/// The global the boot script sets once it drew one: when, in `performance.now()` time.
export const SNAPSHOT_SHOWN_GLOBAL = "__cmuxChatSnapshotShown";
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
    Array.isArray(snapshot.sheets)
  );
}

/// An element's attributes as a record.
export function attributesOf(element: Element): SnapshotAttributes {
  const out: SnapshotAttributes = {};
  for (const attribute of Array.from(element.attributes)) out[attribute.name] = attribute.value;
  return out;
}

/// The `--cmux-*` custom properties of an inline style text, by name.
export function themeVariables(style: string | undefined): Map<string, string> {
  const out = new Map<string, string>();
  if (!style) return out;
  for (const declaration of style.split(";")) {
    const colon = declaration.indexOf(":");
    if (colon < 0) continue;
    const name = declaration.slice(0, colon).trim();
    if (name.startsWith("--cmux-")) out.set(name, declaration.slice(colon + 1).trim());
  }
  return out;
}

/// Whether `snapshot` was drawn for the document as it is now: the same viewport, and `<html>`'s
/// look (its `data-*` attributes) and theme (its `--cmux-*` variables) as the host set them before
/// any page code ran. What the host sets later (the agent theme's own variables) the snapshot carries.
export function fitsDocument(snapshot: ChatSnapshot, doc: Document): boolean {
  const view = doc.defaultView;
  if (!view) return false;
  if (Math.round(view.innerWidth) !== Math.round(snapshot.width)) return false;
  if (Math.round(view.innerHeight) !== Math.round(snapshot.height)) return false;
  const html = doc.documentElement;
  for (const attribute of Array.from(html.attributes)) {
    if (!attribute.name.startsWith("data-")) continue;
    if (snapshot.root[attribute.name] !== attribute.value) return false;
  }
  const saved = themeVariables(snapshot.root.style);
  for (const [name, value] of themeVariables(html.getAttribute("style") ?? undefined))
    if (saved.get(name) !== value) return false;
  return true;
}
