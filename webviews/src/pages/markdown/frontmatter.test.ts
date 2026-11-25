// Front matter reads as a key and value table in the rich view (frontmatter.ts); the raw block keeps
// the text verbatim, so the table is a view only and a save never rewrites it (sourceMap.ts).
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { frontmatterRows, frontmatterTable } from "./frontmatter";
import { frontMatterLength, splitFrontMatter } from "./sourceMap";

const dom = new JSDOM("<!doctype html><html><body></body></html>");
const globals = globalThis as Record<string, unknown>;
const savedDocument = globals.document;
globals.document = dom.window.document;

afterAll(() => {
  globals.document = savedDocument;
  dom.window.close();
});

const YAML = `title: "Search rollout: phase 2"
status: in review # still open
owners: [ada, "grace, h", linus]
tags:
  - search
  - rollout
review:
  due: 2026-12-01
  reviewer: linus
summary: >
  Ships behind a flag,
  one region at a time.
empty:
# a comment line`;

test("top-level keys become rows; lists, nested maps and block scalars show compactly", () => {
  expect(frontmatterRows(YAML)).toEqual([
    { key: "title", value: "Search rollout: phase 2" },
    { key: "status", value: "in review" },
    { key: "owners", value: ["ada", "grace, h", "linus"] },
    { key: "tags", value: ["search", "rollout"] },
    { key: "review", value: "due: 2026-12-01; reviewer: linus" },
    { key: "summary", value: "Ships behind a flag, one region at a time." },
    { key: "empty", value: "" },
  ]);
});

test("front matter with no key: value line has no table", () => {
  expect(frontmatterRows("")).toBeNull();
  expect(frontmatterRows("just some words\n- a list")).toBeNull();
});

test("the table names each key in a row header and a list's items one by one", () => {
  const table = frontmatterTable(frontmatterRows("title: Plan\ntags: [a, b]")!);
  const rows = [...table.querySelectorAll("tr")];
  expect(rows.map((row) => row.querySelector("th")?.textContent)).toEqual(["title", "tags"]);
  expect(rows[0]!.querySelector("th")?.getAttribute("scope")).toBe("row");
  expect([...rows[1]!.querySelectorAll(".md-frontmatter-item")].map((item) => item.textContent)).toEqual(["a", "b"]);
});

test("the table reads the raw block's own text, which stays as written", () => {
  const text = `---\n${YAML}\n---\n\n# Plan\n`;
  const { body } = splitFrontMatter(text.slice(0, frontMatterLength(text)));
  expect(body).toBe(YAML);
  expect(frontmatterRows(body)?.[0]).toEqual({ key: "title", value: "Search rollout: phase 2" });
  // TOML front matter (`key = value`) keeps the folded source alone.
  expect(frontmatterRows('title = "Plan"')).toBeNull();
});
