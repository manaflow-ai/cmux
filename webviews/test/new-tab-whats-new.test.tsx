// What's New in the New Tab page's top-right corner (the host's `whatsNew` push): it shows the host's
// strings, clears on null or anything malformed, and stays out of the page's flow so nothing moves
// when it comes or goes (Leo 2026-11-24: "make sure to have no layout shifts and it's properly placed").
// The gallery's `whats-new-holds-the-page` play measures the same thing in a browser.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { WhatsNewCorner } from "../src/agent-session/acpmux/newtab/WhatsNewCorner";
import { setWhatsNew, whatsNewNotice } from "../src/agent-session/acpmux/newtab/whatsNew";

const push = { title: "Updated to Nightly", whatsNew: "What's New", dismiss: "Dismiss" };

test("the host's push sets the notice, and null or a malformed push clears it", () => {
  setWhatsNew(push);
  expect(whatsNewNotice()).toEqual({ ...push, look: "link" });
  setWhatsNew({ ...push, look: "dot" });
  expect(whatsNewNotice()?.look).toBe("dot");
  setWhatsNew({ title: "Updated" });
  expect(whatsNewNotice()).toBeNull();
  setWhatsNew(push);
  setWhatsNew(null);
  expect(whatsNewNotice()).toBeNull();
});

test("the corner draws the host's strings and only with a handler", () => {
  setWhatsNew(push);
  expect(renderToStaticMarkup(<WhatsNewCorner />)).toBe("");
  const html = renderToStaticMarkup(<WhatsNewCorner onCommand={() => {}} />);
  expect(html).toContain('class="nt-whats-new"');
  expect(html).toContain("What&#x27;s New");
  expect(html).toContain('aria-label="Dismiss"');
  setWhatsNew({ ...push, look: "titled" });
  expect(renderToStaticMarkup(<WhatsNewCorner onCommand={() => {}} />)).toContain("Updated to Nightly");
  setWhatsNew(null);
  expect(renderToStaticMarkup(<WhatsNewCorner onCommand={() => {}} />)).toBe("");
});

test("the corner is out of the page's flow, at a fixed height", () => {
  const css = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/newtab/screen.css"), "utf8");
  const rule = css.match(/\.nt-screen\s*>\s*\.nt-whats-new\s*\{([^}]*)\}/)?.[1] ?? "";
  expect(rule).toMatch(/position:\s*absolute/);
  expect(rule).toMatch(/top:/);
  expect(rule).toMatch(/right:/);
  expect(rule).toMatch(/height:\s*24px/);
});
