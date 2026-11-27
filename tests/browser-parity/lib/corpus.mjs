#!/usr/bin/env node
// Real-site snapshot corpus: public pages frozen as static HTML so snapshot
// invariants can be checked offline and deterministically.
//
//   node tests/browser-parity/lib/corpus.mjs capture [--only NAME]
//     Loads each page in headless Chrome (throwaway profile, logged out),
//     waits for it to settle, and writes fixtures/corpus/NAME.html: the
//     post-JavaScript DOM with scripts removed, stylesheets inlined and
//     pruned to rules that match, fonts and remote images replaced, and
//     iframes inlined as srcdoc.
//   node tests/browser-parity/lib/corpus.mjs oracle [--only NAME]
//     Serves the frozen pages and records, from Chrome, what the snapshot
//     invariants compare against (fixtures/corpus/NAME.oracle.json): the
//     interactive elements in Playwright's AI snapshot with each element's
//     path, and text Chrome does not render. Scenario 27 judges each path's
//     visibility in the engine that renders cmux (fixtures/corpus/gt.js).
//
// Byte budgets for the snapshots of the same frozen pages live in
// fixtures/corpus/size-budgets.json.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadPlaywright } from "./dev-driver.mjs";
import { startFixtureServers } from "./fixture-server.mjs";

const corpusDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "fixtures", "corpus");

export const PAGES = [
  { name: "wikipedia", url: "https://en.wikipedia.org/wiki/WebKit" },
  { name: "hackernews", url: "https://news.ycombinator.com/" },
  { name: "github", url: "https://github.com/manaflow-ai/cmux" },
  { name: "mdn", url: "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array/map" },
  { name: "mdn-iframe", url: "https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/iframe" },
  { name: "npr", url: "https://text.npr.org/" },
  { name: "bbc", url: "https://www.bbc.com/news" },
  { name: "books", url: "https://books.toscrape.com/" },
  { name: "vercel", url: "https://vercel.com/" },
];

// Roles whose elements an agent acts on; recall is checked for these.
export const INTERACTIVE_ROLES = ["button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox",
  "option", "menuitem", "menuitemcheckbox", "menuitemradio", "slider", "spinbutton", "switch", "tab", "treeitem"];

// Runs in the page: freezes the document into static HTML.
function freezeDocument() {
  const TRANSPARENT = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==";
  const doc = document;
  // Stylesheets: keep rules whose selectors match something, drop fonts,
  // imports and remote URLs.
  const stripPseudo = (sel) =>
    sel.replace(/::?[\w-]+(\((?:[^()]|\([^()]*\))*\))?/g, (m) => (/^:(not|is|where|has)\(/.test(m) ? m : "")).trim() || "*";
  const matches = (selectorText) => {
    for (const part of selectorText.split(",")) {
      try {
        if (doc.querySelector(stripPseudo(part))) return true;
      } catch {
        return true;
      }
    }
    return false;
  };
  const cleanCss = (text) =>
    text
      .replace(/cursor:\s*(url\([^)]*\)\s*(\d+\s+\d+\s*)?,\s*)+/g, "cursor: ")
      .replace(/url\((?!["']?data:)[^)]*\)/g, "none");
  const ruleText = (rule) => {
    if (rule instanceof CSSStyleRule) return matches(rule.selectorText) ? cleanCss(rule.cssText) : "";
    if (rule instanceof CSSMediaRule || rule instanceof CSSSupportsRule || (typeof CSSLayerBlockRule !== "undefined" && rule instanceof CSSLayerBlockRule) || (typeof CSSContainerRule !== "undefined" && rule instanceof CSSContainerRule)) {
      const inner = [...rule.cssRules].map(ruleText).filter(Boolean).join("\n");
      if (!inner) return "";
      const head = rule.cssText.slice(0, rule.cssText.indexOf("{"));
      return `${head}{\n${inner}\n}`;
    }
    if (rule instanceof CSSFontFaceRule || rule instanceof CSSImportRule || rule instanceof CSSKeyframesRule) return "";
    return cleanCss(rule.cssText);
  };
  let css = "";
  for (const sheet of doc.styleSheets) {
    let rules;
    try {
      rules = sheet.cssRules;
    } catch {
      continue;
    }
    if (sheet.media && sheet.media.mediaText && !/all|screen/.test(sheet.media.mediaText)) continue;
    css += [...rules].map(ruleText).filter(Boolean).join("\n") + "\n";
  }
  // Custom properties nothing reads (theme palettes) are most of some sites' CSS.
  const inlineStyles = [...doc.querySelectorAll("[style]")].map((e) => e.getAttribute("style")).join("\n");
  const used = new Set();
  let frontier = css + inlineStyles;
  for (let round = 0; round < 8 && frontier; round++) {
    const found = new Set([...frontier.matchAll(/var\(\s*(--[\w-]+)/g)].map((m) => m[1]).filter((v) => !used.has(v)));
    for (const v of found) used.add(v);
    frontier = [...css.matchAll(/[{;]\s*(--[\w-]+)\s*:([^;{}]*)/g)].filter((m) => found.has(m[1])).map((m) => m[2]).join("\n");
  }
  // Only declarations (after `{` or `;`); BEM selectors also contain `--x:`.
  css = css.replace(/([{;]\s*)(--[\w-]+)\s*:[^;{}]*;?/g, (decl, lead, name) => (used.has(name) ? decl : lead));
  for (const el of [...doc.querySelectorAll("style, link[rel~=stylesheet], link[rel=preload], link[rel=prefetch], link[rel=modulepreload], link[rel=icon], link[rel~=alternate], link[rel=manifest], link[rel=preconnect], link[rel=dns-prefetch]")]) el.remove();
  const style = doc.createElement("style");
  style.textContent = css;
  doc.head.appendChild(style);
  // Scripts, event handlers, and anything that fetches or tracks.
  for (const el of [...doc.querySelectorAll("script, noscript, object, embed, base, meta[http-equiv], template")]) el.remove();
  for (const el of doc.querySelectorAll("meta")) {
    if (!el.hasAttribute("charset") && el.getAttribute("name") !== "viewport") el.remove();
  }
  const walker = doc.createTreeWalker(doc.documentElement, NodeFilter.SHOW_COMMENT);
  const comments = [];
  while (walker.nextNode()) comments.push(walker.currentNode);
  for (const c of comments) c.remove();
  for (const el of doc.querySelectorAll("*")) {
    for (const attr of [...el.attributes]) {
      const n = attr.name;
      if (/^on/i.test(n) || n === "nonce" || n === "integrity" || n === "ping" || n === "srcset" || n === "imagesrcset") el.removeAttribute(n);
      else if (n === "style" && /url\(/.test(attr.value)) el.setAttribute("style", cleanCss(attr.value));
      // Long tooltips (full commit messages) and bulky data blobs (MediaWiki's
      // data-mw) do not change what renders; keep the corpus small.
      else if (n === "title" && attr.value.length > 300) el.setAttribute("title", attr.value.slice(0, 300));
      else if (n.startsWith("data-") && attr.value.length > 200) el.removeAttribute(n);
    }
    const tag = el.localName;
    if (tag === "input" && el.type === "hidden") el.removeAttribute("value");
    if (tag === "img" || (tag === "input" && el.type === "image")) {
      const r = el.getBoundingClientRect();
      if (!el.hasAttribute("width") && r.width) el.setAttribute("width", String(Math.round(r.width)));
      if (!el.hasAttribute("height") && r.height) el.setAttribute("height", String(Math.round(r.height)));
      el.setAttribute("src", TRANSPARENT);
      el.removeAttribute("loading");
    }
    if (tag === "source") el.remove();
    if (tag === "video" || tag === "audio") {
      el.removeAttribute("src");
      el.removeAttribute("poster");
    }
    if (tag === "use" && /^(https?:)?\/\//.test(el.getAttribute("href") || "")) el.removeAttribute("href");
    if (tag === "path") el.removeAttribute("d");
    // Links on the page's own host stay root-relative, so they stay on-site
    // when the fixture server serves the page; others become absolute.
    if (tag === "a" && el.getAttribute("href")) {
      el.setAttribute("href", el.host === location.host ? el.pathname + el.search + el.hash : el.href);
    }
    if (tag === "form" && el.getAttribute("action")) el.setAttribute("action", el.action);
    // Live form state becomes markup.
    if (tag === "input" && el.type !== "hidden" && el.type !== "file") {
      if (el.type === "checkbox" || el.type === "radio") el.toggleAttribute("checked", el.checked);
      else el.setAttribute("value", el.value);
    }
  }
  return "<!doctype html>\n" + doc.documentElement.outerHTML;
}

async function settle(page) {
  await page.waitForLoadState("load").catch(() => {});
  await page.waitForLoadState("networkidle", { timeout: 8000 }).catch(() => {});
  // Load lazy content the way a reader scrolling the page would.
  await page.evaluate(async () => {
    for (let y = 0; y < document.body.scrollHeight; y += 700) {
      window.scrollTo(0, y);
      await new Promise((r) => setTimeout(r, 60));
    }
    window.scrollTo(0, 0);
  });
  await page.waitForTimeout(800);
}

// Freezes child frames first, then this one, so each iframe carries its
// content as srcdoc. Tiny frames (trackers, ads' pixels) are removed.
async function freezeFrame(frame) {
  for (const child of frame.childFrames()) {
    const owner = await child.frameElement().catch(() => null);
    if (!owner) continue;
    const box = await owner.boundingBox().catch(() => null);
    if (!box || box.width < 50 || box.height < 50) {
      await owner.evaluate((el) => el.remove()).catch(() => {});
      continue;
    }
    const html = await freezeFrame(child).catch(() => null);
    await owner.evaluate((el, h) => {
      el.removeAttribute("src");
      if (h) el.setAttribute("srcdoc", h);
    }, html).catch(() => {});
  }
  return frame.evaluate(freezeDocument);
}

async function capture(only) {
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    locale: "en-US",
    timezoneId: "UTC",
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
  });
  fs.mkdirSync(corpusDir, { recursive: true });
  try {
    for (const entry of PAGES.filter((p) => !only || p.name === only)) {
      const page = await context.newPage();
      await page.goto(entry.url, { waitUntil: "domcontentloaded", timeout: 60_000 });
      await settle(page);
      const html = await freezeFrame(page.mainFrame());
      const out = path.join(corpusDir, `${entry.name}.html`);
      fs.writeFileSync(out, `<!-- Frozen from ${entry.url} by tests/browser-parity/lib/corpus.mjs. -->\n` + html.replace(/^<!doctype html>\n/, "<!doctype html>\n"));
      console.log(`${entry.name}: ${(fs.statSync(out).size / 1024).toFixed(0)} KB`);
      await page.close();
    }
  } finally {
    await browser.close();
  }
}

// Runs in the page: text Chrome does not render, minus any text that is
// also rendered somewhere, so a match in a snapshot can only be a leak.
function hiddenTexts() {
  const rendered = (el) => {
    for (let e = el; e; e = e.parentElement || (e.getRootNode() && e.getRootNode().host)) {
      if (e.nodeType !== 1) continue;
      if (e.hasAttribute("inert")) return false;
    }
    return el.checkVisibility({ visibilityProperty: true });
  };
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const visible = [];
  const hidden = [];
  while (walker.nextNode()) {
    const node = walker.currentNode;
    const text = node.nodeValue.replace(/\s+/g, " ").trim();
    const parent = node.parentElement;
    if (!text || !parent || /^(script|style|noscript|template|title)$/i.test(parent.localName)) continue;
    (rendered(parent) ? visible : hidden).push(text);
  }
  const seen = visible.join(" \n ");
  const out = [];
  for (const text of new Set(hidden)) if (text.length >= 16 && !seen.includes(text)) out.push(text);
  return out.slice(0, 300);
}

function interactiveFromAiSnapshot(text) {
  const out = [];
  for (const line of text.split("\n")) {
    const m = /^\s*- ([\w-]+)(?: "((?:[^"\\]|\\.)*)")?(.*)$/.exec(line);
    if (!m || !INTERACTIVE_ROLES.includes(m[1])) continue;
    const ref = /\[ref=(\w+)\]/.exec(m[3]);
    out.push({ role: m[1], name: m[2] ? JSON.parse(`"${m[2]}"`) : "", ref: ref && ref[1] });
  }
  return out;
}

// Visibility ground truth shared with scenario 27 (fixtures/corpus/gt.js).
const gtSource = fs.readFileSync(path.join(corpusDir, "gt.js"), "utf8");

async function oracle(only) {
  const { chromium } = loadPlaywright();
  const servers = await startFixtureServers();
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, locale: "en-US", timezoneId: "UTC" });
  try {
    for (const entry of PAGES.filter((p) => !only || p.name === only)) {
      const page = await context.newPage();
      await page.goto(`${servers.origins.primary}/corpus/${entry.name}.html`, { waitUntil: "load" });
      await page.waitForTimeout(300);
      const ai = await page._snapshotForAI();
      const aiText = typeof ai === "string" ? ai : ai.full;
      // _snapshotForAI inlines frames; parse the whole text once. Each entry
      // carries its element's path, so a check can judge visibility in the
      // engine that renders cmux (scenario 27); Chrome's own judgement is
      // only counted here.
      const interactive = [];
      let hiddenInChrome = 0;
      for (const item of interactiveFromAiSnapshot(aiText)) {
        const r = item.ref
          ? await page.locator(`aria-ref=${item.ref}`).evaluate((el, src) => {
              const gt = (0, eval)(src + "; ({ shown, pathOf })");
              return { shown: gt.shown(el), path: gt.pathOf(el) };
            }, gtSource).catch(() => null)
          : null;
        if (r && !r.shown) hiddenInChrome++;
        // Playwright gives no ref to an element without a visible box.
        if (!item.ref) interactive.push({ role: item.role, name: item.name, boxless: true });
        else interactive.push({ role: item.role, name: item.name, path: r ? r.path : null });
      }
      // Hidden text can still name an element (aria-labelledby a hidden
      // tooltip); Chrome prints such names, so they are not leaks.
      const squash = (t) => t.replace(/[\s\u200b-\u200d\u2060\ufeff]+/g, "").toLowerCase();
      const aiSquashed = squash(aiText);
      const hidden = [];
      for (const frame of page.frames()) hidden.push(...(await frame.evaluate(hiddenTexts).catch(() => [])));
      hidden.splice(0, hidden.length, ...hidden.filter((t) => !aiSquashed.includes(squash(t))));
      const record = { url: entry.url, interactive, hiddenInChrome, hidden, chromeAiSnapshotBytes: Buffer.byteLength(aiText) };
      fs.writeFileSync(path.join(corpusDir, `${entry.name}.oracle.json`), JSON.stringify(record, null, 1) + "\n");
      console.log(`${entry.name}: ${interactive.length} interactive (${hiddenInChrome} not shown in Chrome), ${hidden.length} hidden texts`);
      await page.close();
    }
  } finally {
    await browser.close();
    await servers.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [mode, flag, value] = process.argv.slice(2);
  const only = flag === "--only" ? value : null;
  if (mode === "capture") await capture(only);
  else if (mode === "oracle") await oracle(only);
  else throw new Error("usage: corpus.mjs capture|oracle [--only NAME]");
}
