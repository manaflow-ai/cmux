// A page root that follows the app's language live (Settings > General > Language). The page's
// components take a `strings` prop; on each `languagechange` (shared/appLanguage.ts) the root draws
// again with a new `Strings` for the new language, which re-renders every component that reads it
// (the React Compiler's memoized blocks depend on the prop), keeping their state.
import type { ReactNode } from "react";
import type { Root } from "react-dom/client";
import { createStrings, type Strings, type StringTable } from "./i18n";

/** Renders `draw(strings)` into `root` now and again after each language change; `title` names
 *  the document's title. Returns the strings it drew first. */
export function renderLocalized(
  root: Root,
  table: StringTable,
  draw: (strings: Strings) => ReactNode,
  title?: (strings: Strings) => string,
): Strings {
  let strings = createStrings(table);
  const paint = () => {
    if (title) document.title = title(strings);
    root.render(draw(strings));
  };
  paint();
  const view = globalThis.document?.defaultView;
  view?.addEventListener("languagechange", () => {
    const next = createStrings(table);
    if (next.language === strings.language) return;
    strings = next;
    paint();
  });
  return strings;
}
