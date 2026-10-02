// Ground truth for the representation comparison, computed in headless Chrome.
//
// `installSource` is an init script. It records closed shadow roots (the page
// keeps mode "closed"; only this collector can see them) and defines a
// collector under Symbol.for("cmp.gt") in every frame. `collectGroundTruth`
// runs the collector in every frame (same-origin, cross-origin, srcdoc) and
// combines the results with each frame's own visibility and viewport.

export const installSource = `(() => {
  const KEY = Symbol.for("cmp.gt");
  if (window[KEY]) return;
  const closedRoots = new WeakMap();
  const attach = Element.prototype.attachShadow;
  Element.prototype.attachShadow = function (init) {
    const root = attach.call(this, init);
    if (init && init.mode === "closed") closedRoots.set(this, root);
    return root;
  };
  const WIDGET_ROLES = new Set(["button","link","checkbox","radio","switch","tab","menuitem","menuitemcheckbox","menuitemradio","option","combobox","textbox","searchbox","slider","spinbutton","treeitem","gridcell"]);
  const TEXT_INPUTS = new Set(["text","search","email","url","tel","password","number",""]);
  const collapse = (s) => String(s || "").replace(/\\s+/g, " ").trim();
  const rootOf = (el) => el.shadowRoot || closedRoots.get(el) || null;

  function* walk(node, inShadow) {
    for (let c = node.firstElementChild; c; c = c.nextElementSibling) {
      yield [c, inShadow];
      const r = rootOf(c);
      if (r) yield* walk(r, r.mode === "closed" ? "closed" : "open");
      if (c.localName !== "template") yield* walk(c, inShadow);
    }
  }

  function clippedAway(el, rect) {
    for (let a = el.parentElement || (el.getRootNode() && el.getRootNode().host); a && a !== document.documentElement; a = a.parentElement || (a.getRootNode() && a.getRootNode().host)) {
      const cs = getComputedStyle(a);
      if (cs.overflowX === "visible" && cs.overflowY === "visible") continue;
      if (/auto|scroll/.test(cs.overflowX + cs.overflowY)) continue; // reachable by scrolling
      const r = a.getBoundingClientRect();
      if (rect.right <= r.left || rect.left >= r.right || rect.bottom <= r.top || rect.top >= r.bottom) return true;
    }
    return false;
  }

  // "visible", "hidden", or "latent": rendered but transparent, clipped to
  // nothing or pushed off the page. Latent elements are usually skip links
  // or transparent inputs laid over a custom control; a keyboard or pointer
  // reaches them, so they count neither as targets nor as leaks.
  function visibility(el) {
    if (!el.isConnected) return "hidden";
    if (el.checkVisibility && !el.checkVisibility({ checkVisibilityCSS: true })) return "hidden";
    const rects = [...el.getClientRects()].filter((r) => r.width > 0 && r.height > 0);
    let rect = rects[0];
    if (!rect) {
      // display: contents, or a zero-size wrapper around visible content
      const kid = [...el.children].find((k) => k.getBoundingClientRect().width > 0);
      if (!kid) return "hidden";
      rect = kid.getBoundingClientRect();
    }
    if (clippedAway(el, rect)) return "hidden";
    if (el.checkVisibility && !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return "latent";
    if (rect.width <= 1 && rect.height <= 1) return "latent"; // sr-only clip
    const cs = getComputedStyle(el);
    if (cs.clip === "rect(0px, 0px, 0px, 0px)" || cs.clipPath === "inset(50%)") return "latent";
    if (rect.right + scrollX <= 0 || rect.bottom + scrollY <= 0) return "latent"; // off the page's scrollable area
    return "visible";
  }
  const isVisible = (el) => visibility(el) === "visible";

  function inViewport(el) {
    const r = el.getBoundingClientRect();
    return r.right > 0 && r.bottom > 0 && r.left < innerWidth && r.top < innerHeight;
  }

  function textOf(el) {
    let t = collapse(el.innerText !== undefined && el.localName !== "select" ? el.innerText : el.textContent);
    if (!t) t = collapse([...el.querySelectorAll("img[alt],[aria-label]")].map((x) => x.getAttribute("alt") || x.getAttribute("aria-label")).join(" "));
    if (!t && rootOf(el)) t = collapse(rootOf(el).textContent);
    return t;
  }

  function accName(el) {
    const doc = el.getRootNode();
    const lb = el.getAttribute("aria-labelledby");
    if (lb) {
      const t = collapse(lb.split(/\\s+/).map((id) => (doc.getElementById ? doc.getElementById(id) : document.getElementById(id))).filter(Boolean).map((x) => x.textContent).join(" "));
      if (t) return t;
    }
    const al = collapse(el.getAttribute("aria-label"));
    if (al) return al;
    const tag = el.localName;
    if (tag === "input" || tag === "select" || tag === "textarea") {
      const type = (el.getAttribute("type") || "").toLowerCase();
      if (tag === "input" && ["button","submit","reset"].includes(type)) return collapse(el.value) || (type === "reset" ? "Reset" : type === "submit" ? "Submit" : "");
      if (tag === "input" && type === "image") return collapse(el.getAttribute("alt"));
      const labels = el.labels ? [...el.labels] : [];
      if (labels.length) {
        const t = collapse(labels.map((l) => {
          const c = l.cloneNode(true);
          for (const x of c.querySelectorAll("input,select,textarea")) x.remove();
          return c.textContent;
        }).join(" "));
        if (t) return t;
      }
      return collapse(el.getAttribute("title")) || collapse(el.getAttribute("placeholder"));
    }
    if (tag === "img") return collapse(el.getAttribute("alt"));
    // A composite item (tree item, menu item, option) is named by its own
    // content, not by nested groups of further items.
    if (el.querySelector("[role=group],[role=tree],[role=menu],[role=listbox],ul,ol")) {
      const c = el.cloneNode(true);
      for (const x of c.querySelectorAll("[role=group],[role=tree],[role=menu],[role=listbox],ul,ol")) x.remove();
      const t = collapse(c.textContent);
      if (t) return t.slice(0, 200);
    }
    return textOf(el).slice(0, 200) || collapse(el.getAttribute("title"));
  }

  function roleOf(el) {
    const r = (el.getAttribute("role") || "").trim().split(/\\s+/)[0];
    if (r) return r;
    const tag = el.localName;
    const type = (el.getAttribute("type") || "").toLowerCase();
    if (tag === "a" || tag === "area") return "link";
    if (tag === "button" || tag === "summary") return "button";
    if (tag === "select") return el.multiple || el.size > 1 ? "listbox" : "combobox";
    if (tag === "textarea") return "textbox";
    if (tag === "input") {
      if (["button","submit","reset","image","file","color"].includes(type)) return "button";
      if (type === "checkbox") return "checkbox";
      if (type === "radio") return "radio";
      if (type === "range") return "slider";
      if (type === "number") return "spinbutton";
      if (type === "search") return "searchbox";
      if (TEXT_INPUTS.has(type)) return "textbox";
      return "textbox";
    }
    if (el.isContentEditable) return "textbox";
    return "generic";
  }

  function interactiveReason(el) {
    const tag = el.localName;
    const role = (el.getAttribute("role") || "").trim().split(/\\s+/)[0];
    if ((tag === "a" || tag === "area") && el.hasAttribute("href")) return "native";
    if (tag === "button" || tag === "select" || tag === "textarea") return "native";
    if (tag === "input") return (el.getAttribute("type") || "").toLowerCase() === "hidden" ? null : "native";
    if (tag === "summary" && el.parentElement && el.parentElement.localName === "details" && el.parentElement.querySelector(":scope > summary") === el) return "native";
    if (WIDGET_ROLES.has(role)) return "role";
    if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return "contenteditable";
    if (el.hasAttribute("onclick") || typeof el.onclick === "function") return "onclick";
    const ti = el.getAttribute("tabindex");
    if (ti !== null && Number(ti) >= 0 && tag !== "body" && tag !== "html") return "tabindex";
    return null;
  }

  function ariaHidden(el) {
    for (let a = el; a; a = a.parentElement || (a.getRootNode() && a.getRootNode().host)) if (a.getAttribute && a.getAttribute("aria-hidden") === "true") return true;
    return false;
  }

  function collect() {
    const items = [];
    const hiddenTexts = [];
    const visibleTexts = new Set();
    const root = document.body || document.documentElement;
    const walker = function* () { yield [root, false]; yield* walk(root, false); };
    const visCache = new Map();
    const status = (el) => { if (!visCache.has(el)) visCache.set(el, visibility(el)); return visCache.get(el); };
    const vis = (el) => status(el) === "visible";
    const INTERACTIVE_SEL = "a[href],button,input:not([type=hidden]),select,textarea,summary,[contenteditable=''],[contenteditable=true],[role=button],[role=link],[role=checkbox],[role=tab],[role=menuitem],[role=option],[role=textbox],[role=combobox]";
    for (const [el, shadow] of walker()) {
      let reason = interactiveReason(el);
      // A click-handler or tabindex container around other controls (a list
      // row, a card) is not a separate target; the controls inside are.
      if ((reason === "onclick" || reason === "tabindex") && el.querySelector(INTERACTIVE_SEL)) reason = null;
      if (reason) {
        const st = status(el);
        items.push({
          role: roleOf(el), name: accName(el), tag: el.localName, reason, shadow: shadow || null,
          visible: st === "visible", latent: st === "latent", ariaHidden: ariaHidden(el), inViewport: st === "visible" && inViewport(el),
          id: el.id || null, href: el.getAttribute("href"),
        });
      }
      if (["script","style","noscript","template","head"].includes(el.localName)) continue;
      for (let n = el.firstChild; n; n = n.nextSibling) {
        if (n.nodeType !== 3) continue;
        const t = collapse(n.data);
        if (t.length < 6) continue;
        const st = status(el);
        if (st !== "hidden") visibleTexts.add(t.toLowerCase());
        else if (hiddenTexts.length < 400) hiddenTexts.push(t.slice(0, 80));
      }
    }
    // Hidden text counts only when it is long enough to be specific and does
    // not also appear in visible text.
    const corpus = [...visibleTexts].join(" | ");
    const hidden = [...new Set(hiddenTexts)].filter((t) => t.length >= 12 && !corpus.includes(t.toLowerCase()));
    return { url: location.href, items, hiddenTexts: hidden, scroll: { w: innerWidth, h: innerHeight } };
  }

  Object.defineProperty(window, KEY, { value: { collect, isVisible, inViewport }, enumerable: false });
})();`;

const KEY = 'Symbol.for("cmp.gt")';

async function ensure(frame) {
  const has = await frame.evaluate(`!!window[${KEY}]`).catch(() => false);
  if (!has) await frame.evaluate(installSource).catch(() => {});
}

// Visibility and viewport of each frame's owner <iframe>, up to the top.
async function frameChain(frame) {
  let visible = true;
  let inViewport = true;
  const path = [];
  for (let f = frame; f.parentFrame(); f = f.parentFrame()) {
    const owner = await f.frameElement().catch(() => null);
    if (!owner) return { visible: false, inViewport: false, path };
    const parent = f.parentFrame();
    await ensure(parent);
    const r = await owner.evaluate((el, k) => {
      const api = window[Symbol.for(k)];
      return api ? { v: api.isVisible(el), vp: api.isVisible(el) && api.inViewport(el), id: el.id || el.title || el.name || "" } : { v: true, vp: true, id: "" };
    }, "cmp.gt").catch(() => ({ v: false, vp: false, id: "" }));
    visible &&= r.v;
    inViewport &&= r.vp;
    path.unshift(r.id);
  }
  return { visible, inViewport, path };
}

export async function collectGroundTruth(page) {
  const out = { items: [], hiddenTexts: [], frames: [] };
  for (const frame of page.frames()) {
    await ensure(frame);
    const r = await frame.evaluate(`window[${KEY}] ? window[${KEY}].collect() : null`).catch((e) => ({ error: String(e.message || e) }));
    if (!r || r.error) {
      out.frames.push({ url: frame.url(), error: r ? r.error : "no collector" });
      continue;
    }
    const chain = frame === page.mainFrame() ? { visible: true, inViewport: true, path: [] } : await frameChain(frame);
    const crossOrigin = (() => {
      if (frame.url() === "about:srcdoc") return false;
      try {
        return new URL(frame.url()).origin !== new URL(page.url()).origin;
      } catch {
        return false;
      }
    })();
    const frameInfo = { url: frame.url(), depth: chain.path.length, visible: chain.visible, crossOrigin, srcdoc: frame.url() === "about:srcdoc" };
    out.frames.push(frameInfo);
    for (const it of r.items) {
      out.items.push({ ...it, visible: it.visible && chain.visible, inViewport: it.inViewport && chain.inViewport, frameDepth: chain.path.length, crossOrigin, srcdoc: frameInfo.srcdoc });
    }
    if (chain.visible) out.hiddenTexts.push(...r.hiddenTexts);
  }
  return out;
}
