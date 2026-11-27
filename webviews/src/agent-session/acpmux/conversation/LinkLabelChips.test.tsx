// A link whose label is itself a path or a URL (`[file:///a.html](file:///a.html)`) is one chip:
// the label drew its own path chip inside the link's chip, so the reply showed two file icons.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./Markdown";
import { setChipHost } from "../chips/host";
import { resetLinkStore, seedLinkStore } from "../chips/linkStore";
import { relativeCodePath } from "../chips/paths";

const html = (markdown: string) => renderToStaticMarkup(<Markdown>{markdown}</Markdown>).replaceAll("<wbr/>", "");
const chips = (markdown: string) => html(markdown).match(/class="(?:cv-link )?cv-chip\b/g)?.length ?? 0;
const labels = (markdown: string) =>
  [...html(markdown).matchAll(/<span class="cv-chip__label">(.*?)<\/span>/g)].map((match) => match[1]);

const LAB = "file:///Users/me/outputs/lab/background-visibility-lab.html";

test("a file link labelled with its own URL is one chip with the file's name", () => {
  expect(chips(`[${LAB}](${LAB})`)).toBe(1);
  expect(labels(`[${LAB}](${LAB})`)).toEqual(["background-visibility-lab.html"]);
});

test("a file link labelled with its path, in code or not, is one chip with the file's name", () => {
  for (const label of ["/Users/me/outputs/lab/a.html", "`/Users/me/outputs/lab/a.html`"]) {
    expect(chips(`[${label}](/Users/me/outputs/lab/a.html)`)).toBe(1);
    expect(labels(`[${label}](/Users/me/outputs/lab/a.html)`)).toEqual(["a.html"]);
  }
  expect(labels("[/Users/me/repo/src/app.ts:12](/Users/me/repo/src/app.ts:12)")).toEqual(["app.ts:12"]);
});

test("a file link with its own words keeps them, and a path in them stays text", () => {
  expect(labels("[the lab](/Users/me/outputs/lab/a.html)")).toEqual(["the lab"]);
  expect(chips(`[open ${LAB} now](${LAB})`)).toBe(1);
  expect(chips("[`/Users/me/b.html` copy](/Users/me/outputs/lab/a.html)")).toBe(1);
});

test("a web link labelled with a URL is one chip", () => {
  expect(chips("[https://example.com/a](https://example.com/a)")).toBe(1);
  expect(chips(`[${LAB}](https://example.com/a)`)).toBe(1);
});

test("a path or URL outside a link is still its chip", () => {
  expect(chips(`See ${LAB} and https://example.com/a.`)).toBe(2);
});

// A path from the session's folder in code (`outputs/lab/a.html`) was code the reader had to ask a
// link for; it is the file's chip when the host finds the file, and code otherwise.
test("a relative path in code is its file's chip once the host finds it, else code", () => {
  setChipHost(async () => ({}));
  try {
    const source = "Lab: `outputs/lab/background-visibility-lab.html`.";
    expect(html(source)).toContain('<code class="cv-code">outputs/lab/background-visibility-lab.html</code>');
    seedLinkStore({ paths: { "outputs/lab/background-visibility-lab.html": { place: "root", folder: false } } });
    expect(labels(source)).toEqual(["background-visibility-lab.html"]);
    expect(html(source)).toContain('data-path="outputs/lab/background-visibility-lab.html"');
    seedLinkStore({ paths: { "outputs/lab/gone.html": { place: "missing", folder: false } } });
    expect(html("`outputs/lab/gone.html`")).toContain('<code class="cv-code">outputs/lab/gone.html</code>');
  } finally {
    setChipHost(undefined);
    resetLinkStore();
  }
});

test("look-alikes of a relative path stay code", () => {
  for (const text of ["example.com/a.js", "owner/repo", "src/*.ts", "a b/c.ts", "src/app.ts:12", "outputs/lab/"])
    expect(relativeCodePath(text)).toBeUndefined();
  expect(relativeCodePath(".github/workflows/ci.yml")).toBe(".github/workflows/ci.yml");
});
