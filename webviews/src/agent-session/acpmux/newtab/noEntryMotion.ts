// The New Tab has no entry animations (Leo 2026-10-22: "we should basically have no entry
// animations a lot of the time, esp here all over the new tab area... exit animations are ok
// tho."). Its menus, popovers, hover cards and tooltips portal outside the page (to the pane's
// root or the body), so the page marks the document root while it shows, and newtab/noEntry.css
// sets the open tokens to 0 under that mark: what the page shows or opens is drawn in the frame
// it lands in, and only exits keep their fades. test/new-tab-no-entry-motion.test.ts holds it.
import { useLayoutEffect } from "react";
import "./noEntry.css";

/// How many New Tab pages show in each document (a gallery can draw several at once).
const shownPages = new WeakMap<Document, number>();

/// Marks `document.documentElement` with `data-new-tab` while the calling page is mounted; the
/// mark leaves with the last one.
export function useNoEntryMotion(): void {
  useLayoutEffect(() => {
    if (typeof document === "undefined") return;
    const doc = document;
    shownPages.set(doc, (shownPages.get(doc) ?? 0) + 1);
    doc.documentElement.dataset.newTab = "";
    return () => {
      const left = (shownPages.get(doc) ?? 1) - 1;
      if (left > 0) {
        shownPages.set(doc, left);
        return;
      }
      shownPages.delete(doc);
      delete doc.documentElement.dataset.newTab;
    };
  }, []);
}
