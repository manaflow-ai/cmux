// Leo 2026-11-23, on the Updated card: "updated to ellipsis, what's newwith unnecessary gap at end +
// useless up arrow." The title keeps its words (no ellipsis) and What's New has no arrow.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const dir = path.join(import.meta.dir, "../src/pages/changelog");
const css = fs.readFileSync(path.join(dir, "updateSurfaces.css"), "utf8");
const tsx = fs.readFileSync(path.join(dir, "UpdateSurfaces.tsx"), "utf8");

test("the card's title never truncates", () => {
  const rule = css.match(/\.wn-updated \.wn-card-title \{[^}]*\}/)?.[0] ?? "";
  expect(rule).toContain("flex: none");
  expect(rule).not.toContain("text-overflow");
});

test("the What's New link has no arrow and sits after the title in the shipped row", () => {
  const link = tsx.match(/className="wn-card-link"[\s\S]*?<\/button>/)?.[0] ?? "";
  expect(link).not.toContain("↗");
  expect(css).not.toMatch(/data-shape="row"\]\) \.wn-card-link \{ margin-left: auto/);
});
