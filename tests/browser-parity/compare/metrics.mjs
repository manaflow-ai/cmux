// Parsing and scoring for the representation comparison.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
let encoder = null;
try {
  const { Tiktoken } = require("js-tiktoken/lite");
  const o200k = require("js-tiktoken/ranks/o200k_base");
  encoder = new Tiktoken(o200k.default ?? o200k);
} catch {
  encoder = null;
}
export const TOKENIZER = encoder ? "o200k_base (js-tiktoken)" : "bytes/4 (js-tiktoken not installed)";
export function tokens(text) {
  if (!text) return 0;
  if (!encoder) return Math.ceil(Buffer.byteLength(text) / 4);
  return encoder.encode(text, "all").length;
}

// Addresses a tool gives the model for acting on an element.
export const REF_RE = {
  cmux: /\[ref=([^\]\s]+)\]/,
  "cmux-i": /\[ref=([^\]\s]+)\]/,
  aside: /\[ref=([^\]\s]+)\]/,
  "aside-i": /\[ref=([^\]\s]+)\]/,
  "pw-mcp": /\[ref=([^\]\s]+)\]/,
  "chatgpt-ax": /^[~+]?\t*(\d+) /,
  "chatgpt-dom": /node_id=(\d+)/,
  "chatgpt-pw": null,
  "chatgpt-live-ax": /^[~+]?\t*(\d+) /,
  "chatgpt-live-dom": /node_id=(\d+)/,
  "chatgpt-live-pw": null,
  "browser-use": /(?:^|[\s|])\*?\[(\d+)\]</,
  stagehand: /\[(\d+-\d+)\]/,
};

export const norm = (s) =>
  String(s ?? "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/\\n/g, " ")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();

// A name matches when its first words appear as whole words; tools truncate
// long names (dom_cua at 160 characters, browser-use at 100).
export function nameKey(name) {
  const n = norm(name);
  if (n.length <= 40) return n;
  const cut = n.slice(0, 40);
  return cut.slice(0, cut.lastIndexOf(" ") > 10 ? cut.lastIndexOf(" ") : 40);
}

const indentOf = (line) => {
  const m = /^[~+]?([\t ]*)/.exec(line)[1];
  return m.replace(/\t/g, "  ").length;
};

// Items: one per line that carries an address. An item's block is its line
// plus following deeper lines without their own address (browser-use and
// Aside put a label or text on child lines). `context` adds the two lines
// before the item and the sibling line after it, where browser-use puts a
// field's label text.
export function parseItems(tool, text) {
  const re = REF_RE[tool];
  const lines = (text ?? "").split("\n");
  const items = [];
  const plain = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const m = re ? re.exec(line) : null;
    if (!m) {
      plain.push(line);
      continue;
    }
    const ind = indentOf(line);
    const block = [line];
    for (let j = i + 1; j < lines.length && indentOf(lines[j]) > ind && !(re && re.exec(lines[j])); j++) block.push(lines[j]);
    const after = lines[i + block.length];
    const context = [...lines.slice(Math.max(0, i - 2), i), after !== undefined && indentOf(after) >= ind ? after : ""].filter((l) => l && !(re && re.exec(l)));
    items.push({ ref: m[1], line, block: block.join("\n"), context: context.join("\n"), index: i });
  }
  return { items, lines };
}

// Role classes and the words each tool uses for them.
const CLASS_WORDS = {
  link: /\blink\b|<a[\s>]|\/url:/i,
  button: /button|<summary|summary|disclosure|check ?box|toggle|<input[^>]*type=(submit|button|reset|file|image)|\bfile\b/i,
  textbox: /textbox|text ?field|text entry|searchbox|search ?field|search|text ?area|<input|<textarea|editable|combo ?box|contenteditable|generic/i,
  checkbox: /check ?box|type=checkbox|switch/i,
  radio: /radio/i,
  combobox: /combo ?box|<select|pop ?up button|popup|listbox|list box|menu ?button|\blist\b|select/i,
  listbox: /listbox|list box|<select|\blist\b|select|combo ?box/i,
  option: /./,
  tab: /\btab\b|role=tab/i,
  slider: /slider|range|spin/i,
  spinbutton: /spin|<input|text ?field|textbox/i,
  menuitem: /menu ?item|menuitem/i,
  switch: /switch|check ?box/i,
  treeitem: /tree ?item|treeitem|row|outline/i,
  generic: /./,
};
export function roleClass(role) {
  if (/^menuitem/.test(role)) return "menuitem";
  if (role === "searchbox") return "textbox";
  if (role === "gridcell") return "generic";
  return CLASS_WORDS[role] ? role : "generic";
}
const compatible = (gtRole, item) => CLASS_WORDS[roleClass(gtRole)].test(item.line);

const containsName = (hay, key) => key && ` ${norm(hay)} `.includes(` ${key} `);

// Recall: visible interactive ground-truth elements that the tool both
// mentions (compatible role, name) and gives an address. Strict matches the
// item's own block; lenient also accepts the two lines before it.
export function scoreRecall(tool, text, gt, { viewportOnly = false } = {}) {
  const { items, lines } = parseItems(tool, text);
  const all = gt.items.filter((x) => x.visible && !x.ariaHidden && (!viewportOnly || x.inViewport));
  const named = all.filter((x) => nameKey(x.name));
  const used = new Set();
  const matched = new Map();
  for (const pass of ["strict", "lenient"]) {
    for (const g of named) {
      if (matched.has(g)) continue;
      const key = nameKey(g.name);
      const it = items.find((it, i) => !used.has(i) && compatible(g.role, it) && containsName(pass === "strict" ? it.block : `${it.context}\n${it.block}`, key));
      if (it) {
        used.add(items.indexOf(it));
        matched.set(g, pass);
      }
    }
  }
  const whole = norm(lines.join("\n"));
  const mentioned = named.filter((g) => ` ${whole} `.includes(` ${nameKey(g.name)} `)).length;
  const strict = [...matched.values()].filter((p) => p === "strict").length;
  return {
    denominator: named.length,
    unnamed: all.length - named.length,
    strict: named.length ? strict / named.length : null,
    lenient: named.length ? matched.size / named.length : null,
    mentioned: named.length ? mentioned / named.length : null,
    misses: named.filter((g) => !matched.has(g)).slice(0, 12).map((g) => `${g.role} "${g.name.slice(0, 40)}"`),
    usedItems: used,
    items,
  };
}

// Interactive-looking items (a widget role word on the line).
const WIDGET_LINE = /\b(link|button|textbox|text ?field|checkbox|check ?box|radio|combo ?box|combobox|listbox|option|tab|slider|switch|menu ?item|searchbox|spinbutton|pop ?up button)\b|<(a|button|input|select|textarea|summary)\b/i;

// Precision: of the tool's addressable interactive-looking items, the share
// that match only hidden ground-truth elements (leaks), and hidden text that
// appears anywhere in the output.
export function scorePrecision(tool, text, gt) {
  const recall = scoreRecall(tool, text, gt);
  const widgetItems = recall.items.filter((it) => WIDGET_LINE.test(it.line));
  const hidden = gt.items.filter((x) => !x.visible && !x.latent && nameKey(x.name));
  const visibleKeys = new Set(gt.items.filter((x) => x.visible || x.latent).map((x) => nameKey(x.name)));
  let leaks = 0;
  let flagged = 0;
  const leakExamples = [];
  const usedHidden = new Set();
  recall.items.forEach((it, i) => {
    if (recall.usedItems.has(i) || !WIDGET_LINE.test(it.line)) return;
    const h = hidden.find((g) => !usedHidden.has(g) && !visibleKeys.has(nameKey(g.name)) && containsName(it.block, nameKey(g.name)));
    if (h) {
      usedHidden.add(h);
      // A tool that marks the element hidden tells the model; not a leak.
      if (/\[hidden\]/.test(it.line)) {
        flagged++;
        return;
      }
      leaks++;
      if (leakExamples.length < 6) leakExamples.push(it.line.trim().slice(0, 100));
    }
  });
  const whole = ` ${norm(text)} `;
  const hiddenTexts = [...new Set(gt.hiddenTexts.map((t) => nameKey(t)).filter((k) => k.length >= 6))];
  const leakedTexts = hiddenTexts.filter((k) => whole.includes(` ${k} `));
  return {
    widgetItems: widgetItems.length,
    leakedItems: leaks,
    flaggedHidden: flagged,
    leakRate: widgetItems.length ? leaks / widgetItems.length : 0,
    leakExamples,
    hiddenTexts: hiddenTexts.length,
    leakedTexts: leakedTexts.length,
    leakedTextExamples: leakedTexts.slice(0, 6),
  };
}
