import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { EmptyState } from "./EmptyState";

// Lawrence (2026-10-06): remove what doesn't need to be there. A new chat's hero is the
// glyph and one line; the composer below is how it starts, so no New or Import buttons.
test("a new chat's hero has no buttons", () => {
  const html = renderToStaticMarkup(<EmptyState project="app" />);
  expect(html).toContain('class="acpmux-empty-project">app</span>');
  expect(html).not.toContain("<button");
  expect(html).not.toContain("Import and sync");
});
