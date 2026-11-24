// App health's gallery entries draw the indicator's words, never its raw keys: both read the surface's own
// catalog (galleryStrings' englishTable over app-health/Localizable.xcstrings) on top of the server table. They once
// loaded the server page's table and rendered "appHealth.line.repairing" (beyer-themes-beyond sweep,
// error-repair finding 4).
import { expect, test } from "bun:test";
import { createElement, type ComponentType } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import health from "../src/app-health/AppHealth.gallery";
import footer from "../src/app-health/AppHealthFooterRow.gallery";

for (const entry of [health, footer])
  test(`${entry.id}: every variant draws words, not appHealth.* keys`, async () => {
    const View = (await entry.load()) as ComponentType<Record<string, unknown>>;
    const names = Object.keys(entry.variants);
    expect(names.length).toBeGreaterThan(0);
    let drawn = 0;
    for (const name of names) {
      const html = renderToStaticMarkup(createElement(View, entry.variants[name].props as Record<string, unknown>));
      expect({ name, raw: html.match(/appHealth\.[a-zA-Z.]+/g) }).toEqual({ name, raw: null });
      if (html.replace(/<[^>]+>/g, "").trim()) drawn++;
    }
    expect(drawn).toBeGreaterThan(0);
  });
