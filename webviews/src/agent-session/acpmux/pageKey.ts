// Whether this page is the key one: its window is the key window and its web view has the keyboard.
// A field can hold DOM focus while it is not (the window is in the background, another pane has the
// keyboard, the New Tab page focused its field before the user came to it). Then the composer draws
// no caret, as the Claude app's caret shows only while its composer is focused (composerStates.css,
// `:root[data-page-inactive]`). The box itself looks the same focused or not.
//
// The page is key when `document.hasFocus()` and visible; the window's `focus` and `blur`, the
// document's visibility, and a key or press on the page (the user is here) keep it current.
//
// It is the page's one projection of "the person is at this page": code that must wait for that
// (the one-time Cloud hint's claim, cloudChatHintModel.ts) reads `pageIsKey` and `watchPageKey`,
// and adds no focus or visibility listener of its own.

const watchers = new WeakMap<Document, Set<() => void>>();

/// Whether `doc`'s page is the key one now (a page with no `installPageKey` counts as key).
export function pageIsKey(doc: Document = document): boolean {
  return doc.documentElement.dataset.pageInactive === undefined;
}

/// Calls `run` each time `doc`'s page becomes the key one or stops being it. Returns the unwatch.
export function watchPageKey(run: () => void, doc: Document = document): () => void {
  const set = watchers.get(doc) ?? new Set<() => void>();
  watchers.set(doc, set);
  set.add(run);
  return () => void set.delete(run);
}

/// Marks `document`'s root `data-page-inactive` while the page is not the key one. Returns the
/// uninstaller.
export function installPageKey(doc: Document = document): () => void {
  const view = doc.defaultView;
  if (!view) return () => undefined;
  const root = doc.documentElement;
  const set = (key: boolean) => {
    if (key === pageIsKey(doc)) return;
    if (key) delete root.dataset.pageInactive;
    else root.dataset.pageInactive = "";
    for (const run of watchers.get(doc) ?? []) run();
  };
  const check = () => set(doc.visibilityState !== "hidden" && doc.hasFocus());
  const key = () => set(true);
  const away = () => set(false);
  check();
  view.addEventListener("focus", key);
  view.addEventListener("blur", away);
  doc.addEventListener("visibilitychange", check);
  doc.addEventListener("pointerdown", key, true);
  // ui-allow: a key press only marks the page key; it handles no key.
  doc.addEventListener("keydown", key, true);
  return () => {
    view.removeEventListener("focus", key);
    view.removeEventListener("blur", away);
    doc.removeEventListener("visibilitychange", check);
    doc.removeEventListener("pointerdown", key, true);
    doc.removeEventListener("keydown", key, true);
    delete root.dataset.pageInactive;
  };
}
