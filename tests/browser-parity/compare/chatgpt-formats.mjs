// Reproductions of two ChatGPT for Chrome text formats from the behavioral
// spec in docs/browser-repl/chatgpt-ax-spec.md (sections 7 and 8). They are
// written from the spec, not run from the plugin, and the comparison labels
// them as reproduced.

// Section 7, `tab.dom_cua.get_visible_dom()`: one line per visible interactive
// element in the viewport, `<tag node_id=N attrs>TEXT</tag>`.
const visibleDomSource = `(() => {
  const KEY = Symbol.for("cmp.domcua");
  const state = window[KEY] || (window[KEY] = { refs: new WeakMap(), next: 1 });
  const ROLES = new Set(["button","checkbox","combobox","link","menuitem","option","radio","slider","spinbutton","switch","tab","textbox"]);
  const TAGS = new Set(["a","button","details","input","option","select","summary","textarea"]);
  const ATTRS = ["aria-disabled","aria-label","contenteditable","href","name","placeholder","role","title","type","value"];
  const BOOLS = ["checked","disabled","multiple","readonly","required","selected"];
  const CRED = /user[-_ ]?name|e[-_ ]?mail|one[-_ ]?time[-_ ]?code|password|passcode|passwd|\\botp\\b|\\b(?:2fa|mfa)\\b|phone|mobile|\\btel\\b/i;
  const ws = (s) => String(s).replace(/[\\t\\n\\r\\f]+/g, " ");
  const esc = (s) => ws(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const interactive = (el) => {
    if (TAGS.has(el.localName)) return true;
    const ce = el.getAttribute("contenteditable");
    if (ce !== null && ce !== "false") return true;
    if (el.hasAttribute("href") || el.hasAttribute("onclick")) return true;
    if (ROLES.has((el.getAttribute("role") || "").trim())) return true;
    const ti = el.getAttribute("tabindex");
    return ti !== null && Number(ti) >= 0;
  };
  const excluded = (el) => el.getAttribute("aria-hidden") === "true" || el.hasAttribute("hidden") || (el.localName === "input" && (el.getAttribute("type") || "").toLowerCase() === "hidden");
  const visible = (el) => {
    const cs = getComputedStyle(el);
    if (cs.visibility !== "visible" || cs.display === "none" || cs.pointerEvents === "none" || Number(cs.opacity) <= 0.01) return false;
    const vw = visualViewport ? visualViewport.width : innerWidth, vh = visualViewport ? visualViewport.height : innerHeight;
    return [...el.getClientRects()].some((r) => r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < vw && r.top < vh);
  };
  const text = (el) => {
    const parts = [];
    let n = 0;
    const visit = (node) => {
      if (n >= 160) return;
      if (node.nodeType === 3) { const t = node.data.replace(/\\s+/g, " ").trim(); if (t) { parts.push(t); n += t.length + 1; } return; }
      if (node.nodeType !== 1 && node.nodeType !== 11) return;
      if (node.nodeType === 1 && ["script","style","noscript","template"].includes(node.localName)) return;
      if (node.nodeType === 1 && node.shadowRoot) visit(node.shadowRoot);
      for (let c = node.firstChild; c; c = c.nextSibling) visit(c);
    };
    visit(el);
    return parts.join(" ").replace(/\\s+/g, " ").trim().slice(0, 160);
  };
  const out = [];
  const walk = (root) => {
    for (let el = root.firstElementChild; el; el = el.nextElementSibling) {
      if (el.id === "codex-agent-overlay-root") continue;
      if (interactive(el) && !excluded(el) && visible(el)) {
        let ref = state.refs.get(el);
        if (!ref) { ref = state.next++; state.refs.set(el, ref); }
        const attrs = [];
        const cred = el.localName === "input" && CRED.test(["type","autocomplete","id","name","placeholder","aria-label","title"].map((a) => el.getAttribute(a) || "").join(" "));
        for (const a of ATTRS) {
          let v = a === "value" && "value" in el && ["input","textarea","select"].includes(el.localName) ? el.value : el.getAttribute(a);
          if (a === "value" && cred) continue;
          if (v) attrs.push(a + '="' + esc(v) + '"');
        }
        for (const b of BOOLS) if (el.hasAttribute(b) || (b === "checked" && el.checked) || (b === "selected" && el.selected)) attrs.push(b + '="true"');
        const t = text(el);
        out.push({ ref, line: t ? "<" + el.localName + " node_id=@@" + (attrs.length ? " " + attrs.join(" ") : "") + ">" + esc(t) + "</" + el.localName + ">" : "<" + el.localName + " node_id=@@" + (attrs.length ? " " + attrs.join(" ") : "") + " />" });
      }
      if (el.shadowRoot) walk(el.shadowRoot);
      walk(el);
    }
  };
  walk(document.documentElement);
  return out;
})()`;

// One page-level node_id space across frames, as the service keeps per tab.
export class VisibleDom {
  constructor(page) {
    this.page = page;
    this.ids = new Map();
    this.next = 1;
  }
  async #frameVisible(frame) {
    const owner = await frame.frameElement().catch(() => null);
    if (!owner) return false;
    return owner.evaluate((el) => {
      const r = el.getBoundingClientRect();
      const cs = getComputedStyle(el);
      return cs.visibility === "visible" && cs.display !== "none" && r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < innerWidth && r.top < innerHeight;
    }).catch(() => false);
  }
  async get() {
    const lines = [];
    let chars = 0;
    const frames = [];
    const visit = async (frame) => {
      frames.push(frame);
      for (const c of frame.childFrames()) if (await this.#frameVisible(c)) await visit(c);
    };
    await visit(this.page.mainFrame());
    const frameIndex = new Map();
    for (const frame of frames) {
      if (!frameIndex.has(frame)) frameIndex.set(frame, frameIndex.size);
      const items = await frame.evaluate(visibleDomSource).catch(() => []);
      for (const it of items) {
        const key = `${frameIndex.get(frame)}:${it.ref}`;
        if (!this.ids.has(key)) this.ids.set(key, this.next++);
        const line = it.line.replace("@@", String(this.ids.get(key)));
        if (lines.length >= 200 || chars + line.length + (lines.length ? 1 : 0) > 20000) return lines.join("\n");
        chars += line.length + (lines.length ? 1 : 0);
        lines.push(line);
      }
    }
    return lines.join("\n");
  }
}

// Section 8, `tab.playwright.domSnapshot()`: Playwright's AI snapshot with
// iframes expanded, then refs and cursor markers removed, images dropped and
// attribute-less generic/listitem/group wrappers unwrapped. Approximation:
// `_snapshotForAI()` expands iframes itself; the service's added
// `[id=…]`/`[name=…]` iframe attributes are not reproduced.
export function simplifyDomSnapshot(yaml) {
  const lines = yaml.split("\n").filter((l) => l.trim());
  if (!lines.some((l) => /^\s*- /.test(l))) return yaml;
  const root = { children: [], indent: -1 };
  const stack = [root];
  for (const raw of lines) {
    const indent = raw.length - raw.trimStart().length;
    const node = { text: raw.trim(), indent, children: [] };
    while (stack.length > 1 && stack[stack.length - 1].indent >= indent) stack.pop();
    stack[stack.length - 1].children.push(node);
    stack.push(node);
  }
  const out = [];
  const emit = (node, depth) => {
    let t = node.text.replace(/ \[ref=[^\]]*\]/g, "").replace(/ \[cursor=[^\]]*\]/g, "");
    if (/^- img\b/.test(t)) return;
    if (/^- (generic|listitem|group)((\s\[[^\]]*\])*)\s*:?\s*$/.test(t)) {
      for (const c of node.children) emit(c, depth);
      return;
    }
    out.push("  ".repeat(depth) + t);
    for (const c of node.children) emit(c, depth + 1);
  };
  for (const c of root.children) emit(c, 0);
  return out.join("\n");
}
