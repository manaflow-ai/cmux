// Whether this page is the key one: its window is the key window and its web view has the keyboard.
// A field can hold DOM focus while it is not (the window is in the background, another pane has the
// keyboard, the New Tab page focused its field before the user came to it). Then the composer draws
// no caret, as the Claude app's caret shows only while its composer is focused (composerStates.css,
// `:root[data-page-inactive]`). The box itself looks the same focused or not.
//
// The page is key when `document.hasFocus()` and visible; the window's `focus` and `blur`, the
// document's visibility, and a key or press on the page (the user is here) keep it current.

/// Marks `document`'s root `data-page-inactive` while the page is not the key one. Returns the
/// uninstaller.
export function installPageKey(doc: Document = document): () => void {
  const view = doc.defaultView;
  if (!view) return () => undefined;
  const root = doc.documentElement;
  const set = (key: boolean) => {
    if (key) delete root.dataset.pageInactive;
    else root.dataset.pageInactive = "";
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
