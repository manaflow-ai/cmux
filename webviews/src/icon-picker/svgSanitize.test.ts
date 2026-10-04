import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { MAX_SVG_BYTES, sanitizeSVG } from "./svgSanitize";

const { window } = new JSDOM("");
Object.assign(globalThis, { XMLSerializer: window.XMLSerializer });
const parser = new window.DOMParser();
const clean = (svg: string) => {
  const result = sanitizeSVG(svg, parser);
  if (!result.ok) throw new Error(result.reason);
  return result.svg;
};
const NS = 'xmlns="http://www.w3.org/2000/svg"';

test("keeps shapes, paint servers and internal references", () => {
  const out = clean(
    `<svg ${NS} viewBox="0 0 10 10"><defs><linearGradient id="g"><stop offset="0" stop-color="#f00"/></linearGradient></defs><rect width="10" height="10" fill="url(#g)"/><use href="#g"/></svg>`,
  );
  expect(out).toContain('fill="url(#g)"');
  expect(out).toContain('href="#g"');
  expect(out).toContain("<rect");
});

test("removes scripts, events, foreignObject, images, styles and animation", () => {
  const out = clean(
    `<svg ${NS} onload="alert(1)"><script>alert(1)</script><foreignObject><div xmlns="http://www.w3.org/1999/xhtml">x</div></foreignObject><image href="https://e.x/a.png"/><style>@import url(https://e.x/a.css)</style><animate attributeName="x"/><circle r="1" onclick="x()" style="fill:url(https://e.x)"/></svg>`,
  );
  for (const banned of [
    "script",
    "alert",
    "foreignObject",
    "<image",
    "<style",
    "@import",
    "animate",
    "onclick",
    "onload",
    "style=",
    "https:",
  ]) {
    expect(out).not.toContain(banned);
  }
  expect(out).toContain("<circle");
});

test("removes external references in href and paint values", () => {
  const out = clean(
    `<svg ${NS} xmlns:xlink="http://www.w3.org/1999/xlink"><use xlink:href="https://e.x/s.svg#a"/><use href="data:image/svg+xml,x"/><path d="M0 0" fill="url(https://e.x/#p)" stroke="javascript:x"/></svg>`,
  );
  expect(out).not.toContain("e.x");
  expect(out).not.toContain("data:");
  expect(out).not.toContain("javascript");
});

test("refuses non-SVG and oversized input", () => {
  expect(sanitizeSVG("<html></html>", parser)).toEqual({ ok: false, reason: "notSVG" });
  expect(sanitizeSVG("<svg", parser)).toEqual({ ok: false, reason: "notSVG" });
  expect(sanitizeSVG(`<svg ${NS}>${" ".repeat(MAX_SVG_BYTES)}</svg>`, parser)).toEqual({
    ok: false,
    reason: "tooLarge",
  });
});
