// cmux browser REPL page agent.
//
// Installed by the driver into every frame's isolated "agent" world. It owns
// this frame's part of the snapshot tree, the ref table, element handles, and
// the DOM helpers the runtime's actionability checks need. Locator semantics
// come from Playwright's InjectedScript so they match Playwright exactly.
//
// Install recipe (drivers build this string once per frame document):
//
//   (() => {
//     const module = {};
//     <vendor/playwright-injected.js>
//     const __cmuxInjectedScriptFactory = module.exports.InjectedScript;
//     <page-agent.js>
//   })();
//
// The agent is stored on globalThis under Symbol.for("cmux.browserRepl.agent")
// as a non-enumerable property. Runtime code reaches it with
// `globalThis[Symbol.for("cmux.browserRepl.agent")]`.
(function (global, injectedFactory, ariaCaches) {
  "use strict";
  const KEY = Symbol.for("cmux.browserRepl.agent");
  if (global[KEY]) return;

  const document = global.document;

  // The app's agent world sees closed shadow roots (WebKit's
  // allowAccessToClosedShadowRoots). WebKit's switch also opens user-agent
  // roots (the internals of <details>, <summary>, <input>, <video>), which
  // are not page content. Only custom elements and these HTML elements can
  // host an author shadow root (DOM Standard, attachShadow), so this world's
  // `shadowRoot` returns a root only for them. Page worlds are unaffected.
  const AUTHOR_SHADOW_HOSTS = new Set(["article", "aside", "blockquote", "body", "div", "footer", "h1", "h2", "h3", "h4",
    "h5", "h6", "header", "main", "nav", "p", "section", "span"]);
  const HTML_NS = "http://www.w3.org/1999/xhtml";
  // A Chromium isolated world has no such switch: the host walks the
  // browser's DOM and hands each closed root to this world
  // (adoptClosedRoot, cdp/closed_roots.rs).
  const closedRoots = new WeakMap();
  const adoptClosedRoot = (host, root) => {
    if (host && root && global.ShadowRoot && root instanceof global.ShadowRoot && root.host === host) closedRoots.set(host, root);
  };
  const shadowRootDescriptor = global.Element && Object.getOwnPropertyDescriptor(global.Element.prototype, "shadowRoot");
  if (shadowRootDescriptor && shadowRootDescriptor.get && shadowRootDescriptor.configurable) {
    const read = shadowRootDescriptor.get;
    Object.defineProperty(global.Element.prototype, "shadowRoot", {
      configurable: true,
      enumerable: shadowRootDescriptor.enumerable,
      get() {
        const root = read.call(this) || closedRoots.get(this);
        if (!root) return null;
        const name = this.localName || "";
        return this.namespaceURI === HTML_NS && (name.includes("-") || AUTHOR_SHADOW_HOSTS.has(name)) ? root : null;
      },
    });
  }

  // `labels` of a form control. WebKit answers each read by scanning the
  // whole document (LabelsNodeList), so naming every button of a large page
  // is quadratic. While the DOM cannot change (a synchronous read such as a
  // snapshot), this world answers from an index built once per tree: the
  // <label> elements of the control's root, keyed by their labeled control.
  // That is the definition of `labels` (HTML, "labeled control"), so the
  // result is the same. Page worlds are unaffected.
  let labelIndex = null;
  const LABELABLE = ["HTMLButtonElement", "HTMLInputElement", "HTMLMeterElement", "HTMLOutputElement", "HTMLProgressElement",
    "HTMLSelectElement", "HTMLTextAreaElement"];
  for (const name of LABELABLE) {
    const proto = global[name] && global[name].prototype;
    const d = proto && Object.getOwnPropertyDescriptor(proto, "labels");
    if (!d || !d.get || !d.configurable) continue;
    const read = d.get;
    Object.defineProperty(proto, "labels", {
      configurable: true,
      enumerable: d.enumerable,
      get() {
        if (!labelIndex) return read.call(this);
        // A hidden input has no labels (null), as the native getter says.
        if (name === "HTMLInputElement" && (this.type || "").toLowerCase() === "hidden") return null;
        // An index the budget cut short has no answer, and WebKit's getter
        // would scan the whole document for each control: the cut read gets
        // no labels (it already says it was cut).
        const found = labelIndex(this);
        return found === null ? [] : found;
      },
    });
  }
  // Building it reads every <label> of the tree, which the page sets the
  // number of, so each one is charged to the read's budget (the snapshot's,
  // else a page-read budget of its own; classic 7f37c374e9f5). An index the
  // budget cut short answers null, and that control has no labels in this
  // read. The labels are read one at a time, never listed whole first: a
  // document's from its live <label> collection; a shadow root (which has
  // no such collection) by a walk of its elements, each one also counted
  // against MAX_NODES.
  let labelBudget = null;
  function* treeLabels(root, cut) {
    if (root.nodeType === 9 /* DOCUMENT_NODE */) {
      const labels = root.getElementsByTagName("label");
      for (let i = 0, label = labels[0]; label; label = labels[++i]) yield label;
      return;
    }
    if (root.nodeType !== 11 /* DOCUMENT_FRAGMENT_NODE */) return;
    let left = MAX_NODES;
    const walker = document.createTreeWalker(root, 1 /* NodeFilter.SHOW_ELEMENT */);
    for (let el = walker.nextNode(); el; el = walker.nextNode()) {
      if (--left < 0) {
        cut.done = true;
        return;
      }
      if (el.localName === "label") yield el;
    }
  }
  function createLabelIndex() {
    const byRoot = new Map();
    return (el) => {
      const root = el.getRootNode();
      let map = byRoot.get(root);
      if (map === undefined) {
        map = new Map();
        const b = labelBudget || (labelBudget = readBudget());
        const cut = { done: false };
        for (const label of treeLabels(root, cut)) {
          if (!spend(b, 1)) {
            cut.done = true;
            break;
          }
          const control = label.control;
          if (!control) continue;
          if (!map.has(control)) map.set(control, []);
          map.get(control).push(label);
        }
        if (cut.done) map = null;
        byRoot.set(root, map);
      }
      return map === null ? null : map.get(el) || [];
    };
  }
  // Runs `fn` with the label index, Playwright's aria caches and a computed
  // style cache. Only for synchronous reads: the DOM must not change inside.
  let styleCache = null;
  function withReadCaches(fn) {
    if (labelIndex) return fn();
    labelIndex = createLabelIndex();
    labelBudget = null;
    styleCache = new Map();
    if (ariaCaches) ariaCaches.begin();
    try {
      return fn();
    } finally {
      if (ariaCaches) ariaCaches.end();
      labelIndex = null;
      labelBudget = null;
      styleCache = null;
    }
  }

  let injected = null;
  if (injectedFactory) {
    const InjectedScript = injectedFactory();
    injected = new InjectedScript(global, {
      isUnderTest: false,
      sdkLanguage: "javascript",
      testIdAttributeName: "data-testid",
      stableRafCount: 1,
      browserName: "webkit",
      isUtilityWorld: true,
      customEngines: [],
    });
  }

  // ---------------------------------------------------------------------------
  // Handles

  // Handles hold their elements weakly: a connected element is kept alive by
  // its document, and one the page dropped cannot be acted on anyway.
  let nextHandle = 1;
  const handleOf = new WeakMap();
  const handles = new Map();
  const weakRef = typeof global.WeakRef === "function" ? (el) => new global.WeakRef(el) : (el) => ({ deref: () => el });
  function handleFor(el) {
    let id = handleOf.get(el);
    if (!id) {
      id = "h" + nextHandle++;
      handleOf.set(el, id);
      handles.set(id, weakRef(el));
    }
    return id;
  }
  function handleElement(id) {
    const entry = handles.get(id);
    return (entry && entry.deref()) || null;
  }
  function element(id) {
    const el = handleElement(id);
    if (!el) throw agentError("stale", "Element handle is no longer available");
    return el;
  }
  // Past this many entries, the ref and handle tables also drop elements
  // that are out of the document (a page that replaces its content keeps
  // adding refs, and WeakRefs are only cleared when the engine collects).
  // A dropped element that returns to the document gets its ref back from
  // `refOf` at the next snapshot.
  const TABLE_SOFT_LIMIT = 5000;
  function pruneHandles() {
    const large = handles.size > TABLE_SOFT_LIMIT;
    for (const [id, entry] of handles) {
      const el = entry.deref();
      if (!el || (large && !el.isConnected)) handles.delete(id);
    }
  }
  function agentError(code, message) {
    const e = new Error(message);
    e.code = code;
    return e;
  }

  const tagOf = (el) => (el.localName || el.tagName || "").toLowerCase();
  const styleOf = (el, pseudo) => {
    if (styleCache && !pseudo) {
      let style = styleCache.get(el);
      if (style === undefined) {
        try {
          style = global.getComputedStyle(el, null);
        } catch {
          style = null;
        }
        styleCache.set(el, style);
      }
      return style;
    }
    try {
      return global.getComputedStyle(el, pseudo || null);
    } catch {
      return null;
    }
  };
  const normalize = (s) => String(s || "").replace(/\s+/g, " ").trim();
  // A random token that lives only in this world (classic's docToken).
  const docToken = (() => {
    const bytes = new Uint8Array(8);
    if (global.crypto && typeof global.crypto.getRandomValues === "function") global.crypto.getRandomValues(bytes);
    else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  })();
  // Where this world cuts a page string, it leaves CUT until the reply is
  // sealed (`reply`). Secrets are masked after the reply leaves the page (the
  // host's frame.observe redaction, the session's secret masking), by
  // matching whole values, so a cut inside a value would hand on its
  // unmasked prefix: sealing drops the CUT_MARGIN characters before each
  // cut, the longest form a masked value takes (4,096 bytes, each character
  // at most 13 characters as an HTML reference, `&#1114111;`), and writes
  // "…" there. CUT is random and lives only in this world, so page text,
  // which may hold any character, cannot forge a cut.
  const CUT = "﷐" + docToken + "﷐";
  const CUT_MARGIN = 13 * 4096;
  // `s` with each cut settled: the text within CUT_MARGIN before it dropped.
  function settleCuts(s) {
    if (typeof s !== "string" || s.indexOf(CUT) === -1) return s;
    let out = "";
    let from = 0;
    for (let i = s.indexOf(CUT); i !== -1; i = s.indexOf(CUT, from)) {
      let end = Math.max(from, i - CUT_MARGIN);
      // Never split a surrogate pair.
      if (end > from && /[\ud800-\udbff]/.test(s[end - 1])) end--;
      out += s.slice(from, end) + "…";
      from = i + CUT.length;
      while (s.startsWith(CUT, from)) from += CUT.length;
    }
    return out + s.slice(from);
  }
  // A safety cap only: the host decides how much of a name to print.
  const capName = (s) => (s.length > 2000 ? s.slice(0, 1999) + CUT : s);

  function parentCrossingShadow(el) {
    if (el.parentElement) return el.parentElement;
    const root = el.parentNode;
    if (root && root.nodeType === 11 && root.host) return root.host;
    return null;
  }

  function isContentEditableHost(el) {
    const ce = el.contentEditable;
    if (ce !== "true" && ce !== "plaintext-only") return false;
    const parent = parentCrossingShadow(el);
    return !(parent && parent.isContentEditable);
  }

  function pseudoText(el, pseudo) {
    const cs = styleOf(el, pseudo);
    if (!cs || cs.display === "none" || cs.visibility === "hidden") return "";
    const content = cs.content;
    if (!content || content === "none" || content === "normal") return "";
    let out = "";
    const re = /"((?:[^"\\]|\\[\s\S])*)"|'((?:[^'\\]|\\[\s\S])*)'/g;
    let m;
    while ((m = re.exec(content))) {
      const raw = m[1] !== undefined ? m[1] : m[2];
      out += raw.replace(/\\([nrtf"'\\])/g, (_, c) => ({ n: "\n", r: "\r", t: "\t", f: "\f" })[c] || c);
    }
    return out;
  }

  function deepActiveElement(doc) {
    let active = doc.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
    return active === doc.body || active === doc.documentElement ? null : active;
  }

  // ---------------------------------------------------------------------------
  // Refs. A ref names one DOM node for the node's life and is never reused in
  // this frame: the host passes `base`, the highest number it has seen here,
  // so numbering continues after the frame loads a new document.

  const refOf = new WeakMap();
  const refRegistry = new Map();
  let refCounter = 0;

  function raiseRefBase(base) {
    if (typeof base === "number" && base > refCounter) refCounter = base;
  }
  function refFor(el) {
    let ref = refOf.get(el);
    if (!ref) {
      ref = "e" + ++refCounter;
      refOf.set(el, ref);
      refRegistry.set(ref, weakRef(el));
    } else if (!refRegistry.has(ref)) refRegistry.set(ref, weakRef(el));
    return ref;
  }
  function refElement(ref) {
    const entry = refRegistry.get(ref);
    const el = entry && entry.deref();
    return el && el.isConnected ? el : null;
  }
  function pruneRefs() {
    const large = refRegistry.size > TABLE_SOFT_LIMIT;
    for (const [ref, entry] of refRegistry) {
      const el = entry.deref();
      if (!el || (large && !el.isConnected)) refRegistry.delete(ref);
    }
  }

  // ---------------------------------------------------------------------------
  // Snapshot tree (plans/cmux-next/browser-repl/README.md, Snapshot). This builds a JSON
  // tree of roles, names, states and text; snapshot.js on the host stitches
  // frames and renders the text. Roles and names come from Playwright's
  // injected script, so they match getByRole().

  const SKIP_TAGS = new Set(["script", "style", "noscript", "template", "head", "meta", "link", "title", "base"]);
  // Structure that carries no meaning for an agent: its text joins the parent.
  // Paragraphs too: their text prints as its own lines either way.
  const FLATTEN_ROLES = new Set(["generic", "none", "presentation", "strong", "emphasis", "code", "mark", "subscript",
    "superscript", "deletion", "insertion", "time", "rowgroup", "paragraph"]);
  const FLATTEN_UNNAMED_ROLES = new Set(["group", "img", "image", "region", "caption"]);
  const INTERACTIVE_ROLES = new Set(["button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox",
    "option", "menuitem", "menuitemcheckbox", "menuitemradio", "slider", "spinbutton", "switch", "tab", "treeitem", "scrollbar"]);
  // Named landmarks, dialogs and lists get refs so a region can be scoped.
  const SCOPE_ROLES = new Set(["banner", "complementary", "contentinfo", "form", "main", "navigation", "region", "search",
    "dialog", "alertdialog", "list", "listbox", "menu", "menubar", "tablist", "tree", "treegrid", "grid"]);
  const CHECKED_ROLES = new Set(["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio", "treeitem", "option"]);
  const SELECTED_ROLES = new Set(["tab", "option", "row", "gridcell", "treeitem", "columnheader", "rowheader"]);
  const VALUE_ROLES = new Set(["slider", "progressbar", "meter", "spinbutton", "scrollbar"]);
  const NO_VALUE_INPUTS = new Set(["checkbox", "radio", "button", "submit", "reset", "image", "hidden"]);
  const NOT_READONLY_INPUTS = new Set(["checkbox", "radio", "file", "button", "submit", "reset", "image", "range", "color", "hidden"]);
  // Options of a closed drop-down the host prints inline (snapshot.js).
  const INLINE_OPTIONS = 10;
  const LEAF_TAGS = new Set(["input", "textarea", "select", "img", "svg", "canvas", "progress", "meter", "video", "audio", "iframe", "frame"]);
  const BREAK = { brk: true };
  // Where a clipped element was left out; text brackets around it close up.
  const DROPPED = { dropped: true };

  // Tables used for page layout (Hacker News, old sites, emails) are not
  // data: their rows and cells flatten into the content, as Chromium's
  // accessibility tree does. A table is data when it declares any header,
  // caption or table structure; otherwise a table that holds or sits in
  // another table, a single row or column, or rows of differing lengths mark
  // it as layout.
  const layoutTables = new WeakMap();
  const TABLE_PART_TAGS = new Set(["table", "thead", "tbody", "tfoot", "tr", "td", "th"]);
  function isLayoutTable(table) {
    let layout = layoutTables.get(table);
    if (layout !== undefined) return layout;
    layout = false;
    if (!table.getAttribute("role") && !table.hasAttribute("summary") && !(Number(table.getAttribute("border")) > 0) &&
        !(table.caption || table.tHead || table.tFoot || table.querySelector(":scope > colgroup"))) {
      const rows = [...table.rows];
      let dataCell = false;
      const lengths = new Set();
      for (const row of rows) {
        let length = 0;
        for (const cell of row.cells) {
          length += cell.colSpan || 1;
          if (tagOf(cell) === "th" || cell.hasAttribute("scope") || cell.hasAttribute("headers") || cell.getAttribute("role")) dataCell = true;
        }
        if (length) lengths.add(length);
      }
      if (!dataCell) {
        const columns = Math.max(0, ...lengths);
        const nested = !!table.querySelector("table") || !!(table.parentElement && table.parentElement.closest("td, th"));
        layout = nested || rows.length <= 1 || columns <= 1 || lengths.size > 1;
      }
    }
    layoutTables.set(table, layout);
    return layout;
  }
  function inLayoutTable(el, tag) {
    if (!TABLE_PART_TAGS.has(tag) || el.getAttribute("role")) return false;
    const table = tag === "table" ? el : el.closest("table");
    return !!table && isLayoutTable(table);
  }

  function roleOf(el) {
    const tag = tagOf(el);
    if (tag === "iframe" || tag === "frame") return "iframe";
    if (inLayoutTable(el, tag)) return "none";
    const explicit = (el.getAttribute("role") || "").trim();
    const role = injected ? injected.utils.getAriaRole(el) : null;
    if (role) return role;
    // Controls with no ARIA role in HTML-AAM, named the way Chromium exposes
    // them. getByRole() does not find these roles; their refs work.
    if (!explicit && tag === "summary") return "button";
    if (!explicit && tag === "canvas") return "canvas";
    if (!explicit && isContentEditableHost(el)) return "textbox";
    return "generic";
  }

  // Roles ARIA names from their content and that hold little else: their
  // content name is how an agent finds them. Containers that ARIA also names
  // from content (rows, cells, list and tree items) would repeat everything
  // their children print, so they take only an author name.
  const CONTENT_NAMED_ROLES = new Set(["button", "link", "heading", "option", "tab", "menuitem", "menuitemcheckbox",
    "menuitemradio", "checkbox", "radio", "switch", "tooltip", "treeitem"]);
  const AUTHOR_NAMED_ONLY_ROLES = new Set(["row", "cell", "gridcell", "columnheader", "rowheader", "listitem",
    "paragraph", "term", "definition", "blockquote", "status", "alert", "log", "note", "article"]);

  function authorName(el) {
    const ids = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
    const labelled = ids.map((id) => (el.ownerDocument.getElementById(id) || {}).textContent || "").join(" ");
    return capName(normalize(labelled || el.getAttribute("aria-label") || ""));
  }

  function nodeName(el, role, includeHidden) {
    if (AUTHOR_NAMED_ONLY_ROLES.has(role)) return authorName(el);
    return accessibleName(el, includeHidden);
  }

  function accessibleName(el, includeHidden) {
    if (!injected) return "";
    let name = injected.utils.getElementAccessibleName(el, !!includeHidden);
    // Playwright names by ARIA role, so a <div> that is a control here (an
    // editable or clickable one, a scroll region) gets its label attributes.
    if (!name && !el.getAttribute("role")) {
      const ids = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
      name = ids.map((id) => (el.ownerDocument.getElementById(id) || {}).textContent || "").join(" ") ||
        el.getAttribute("aria-label") || el.getAttribute("title") || "";
    }
    return capName(normalize(name));
  }

  // What a user can see. An element is *rendered* unless it or an ancestor
  // is display:none or content-visibility:hidden (a closed <details>,
  // hidden=until-found, which WebKit lays out as a block with skipped
  // content), inert, aria-hidden, or clipped away inside a zero-size box
  // with overflow hidden. A rendered element is *visible* when its own
  // visibility is `visible`; an invisible one can still hold visible
  // children. This is Playwright's isElementVisible (checkVisibility, which
  // Playwright skips on WebKit) without its non-empty box test, so an empty
  // progress bar or a zero-height float container still counts.
  function checkVisibility(el) {
    try {
      return typeof el.checkVisibility === "function" ? el.checkVisibility() : true;
    } catch {
      return true;
    }
  }
  const CLIPS = new Set(["hidden", "clip", "scroll", "auto"]);
  // content-visibility needs layout containment, which inline boxes and
  // table parts other than cells ignore.
  const NO_CONTAINMENT_DISPLAYS = new Set(["inline", "table-row", "table-row-group", "table-header-group",
    "table-footer-group", "table-column", "table-column-group", "ruby-base", "ruby-text", "contents"]);
  function skipsContents(style) {
    return style.contentVisibility === "hidden" && !NO_CONTAINMENT_DISPLAYS.has(style.display);
  }
  function isRendered(el, style) {
    if (!style || style.display === "none") return false;
    if (el.hasAttribute("inert")) return false;
    if (style.display === "contents") return true;
    if (!checkVisibility(el)) return false;
    if (CLIPS.has(style.overflowX) || CLIPS.has(style.overflowY)) {
      const r = el.getBoundingClientRect();
      if ((r.width < 1 && CLIPS.has(style.overflowX)) || (r.height < 1 && CLIPS.has(style.overflowY))) return false;
    }
    return true;
  }

  function hasPointerCursor(el, style) {
    if (!style || style.cursor !== "pointer") return false;
    const parent = parentCrossingShadow(el);
    const parentStyle = parent && styleOf(parent);
    return !(parentStyle && parentStyle.cursor === "pointer");
  }

  function isInteractive(el, role, style) {
    if (INTERACTIVE_ROLES.has(role) || role === "canvas") return true;
    const tag = tagOf(el);
    if (tag === "input") return (el.type || "").toLowerCase() !== "hidden";
    if (tag === "button" || tag === "select" || tag === "textarea" || tag === "summary") return true;
    if ((tag === "a" || tag === "area") && el.hasAttribute("href")) return true;
    if ((tag === "video" || tag === "audio") && el.hasAttribute("controls")) return true;
    if (isContentEditableHost(el)) return true;
    const tabindex = el.getAttribute("tabindex");
    if (tabindex !== null && Number(tabindex) >= 0) return true;
    if (el.hasAttribute("onclick") || el.getAttribute("draggable") === "true") return true;
    return hasPointerCursor(el, style);
  }

  function isScrollable(el, style) {
    const tag = tagOf(el);
    if (tag === "html" || tag === "body" || !style) return false;
    const scrolls = (v) => v === "auto" || v === "scroll" || v === "overlay";
    const y = scrolls(style.overflowY) && el.scrollHeight > el.clientHeight + 1;
    const x = scrolls(style.overflowX) && el.scrollWidth > el.clientWidth + 1;
    return x || y;
  }

  function isBlock(style, tag) {
    if (tag === "br") return true;
    const display = style ? style.display : "inline";
    return !!display && !display.startsWith("inline") && display !== "contents" && display !== "none";
  }

  function isDisabled(el) {
    try {
      if (el.matches(":disabled")) return true;
    } catch {}
    for (let cur = el; cur; cur = parentCrossingShadow(cur)) {
      if (cur.getAttribute("aria-disabled") === "true") return true;
    }
    return false;
  }

  function isUserInvalid(el) {
    try {
      return el.matches(":user-invalid");
    } catch {
      return false;
    }
  }

  // Whether the element or something inside it has a non-empty box that is
  // not clipped away (screen-reader-only text uses `clip` or `clip-path`).
  const clippedAway = (style) => !!style && ((style.clip && style.clip !== "auto") || (style.clipPath && style.clipPath !== "none"));
  function hasVisibleBox(el) {
    const r = el.getBoundingClientRect();
    if (r.width >= 1 && r.height >= 1) return true;
    // A zero-size box that clips its overflow shows none of its content.
    const style = styleOf(el);
    if (style && ((r.width < 1 && CLIPPING.has(style.overflowX)) || (r.height < 1 && CLIPPING.has(style.overflowY)))) return false;
    const range = document.createRange();
    const inside = (node) => {
      for (let n = node.firstChild; n; n = n.nextSibling) {
        if (n.nodeType === 3) {
          if (!n.nodeValue.trim()) continue;
          range.selectNodeContents(n);
          const b = range.getBoundingClientRect();
          if (b.width >= 1 && b.height >= 1) return true;
        } else if (n.nodeType === 1) {
          const cs = styleOf(n);
          if (!cs || cs.display === "none" || clippedAway(cs)) continue;
          const b = n.getBoundingClientRect();
          if (b.width >= 1 && b.height >= 1) return true;
          if (inside(n)) return true;
        }
      }
      return false;
    };
    return inside(el);
  }

  // "host/first-segment/…" for a link to another site (hosts that differ
  // after "www." and ignoring subdomains of the same two-label base), capped.
  const siteOf = (host) => host.replace(/^www\./, "").split(".").slice(-2).join(".");
  function offsiteSummary(el) {
    const href = el.href;
    if (!href || typeof href !== "string") return null;
    let url;
    try {
      url = new global.URL(href);
    } catch {
      return null;
    }
    if (!/^https?:$/.test(url.protocol) || !global.location.hostname) return null;
    if (siteOf(url.hostname) === siteOf(global.location.hostname)) return null;
    const segments = url.pathname.split("/").filter(Boolean);
    let out = url.hostname.replace(/^www\./, "") + (segments.length ? "/" + segments[0] : "");
    if (segments.length > 1 || url.search) out += "/…";
    return out.length > 48 ? out.slice(0, 47) + "…" : out;
  }

  function displayUrl(el) {
    const href = el.href;
    if (!href || typeof href !== "string" || /^javascript:/i.test(href)) return null;
    let url;
    try {
      url = new global.URL(href);
    } catch {
      return href;
    }
    if (url.protocol === "data:") return null;
    if (url.origin !== "null" && url.origin === global.location.origin) return url.pathname + url.search + url.hash;
    return url.href.length > 300 ? url.href.slice(0, 299) + "…" : url.href;
  }

  function valueOf(el, role, tag) {
    if (tag === "input") {
      const type = (el.type || "").toLowerCase();
      if (NO_VALUE_INPUTS.has(type)) return null;
      if (type === "file") return el.files && el.files.length ? [...el.files].map((f) => f.name).join(", ") : null;
      if (type === "password") return el.value ? "********" : null;
      return el.value || null;
    }
    if (tag === "textarea") return el.value || null;
    if (tag === "select") {
      if (el.multiple || el.size > 1) return null;
      const option = el.options[el.selectedIndex];
      return option ? normalize(option.label || option.textContent) || null : null;
    }
    if (isContentEditableHost(el)) return normalize(el.innerText) || null;
    if (tag === "progress" || tag === "meter") return el.hasAttribute("value") ? String(el.value) : null;
    if (VALUE_ROLES.has(role)) return el.getAttribute("aria-valuetext") || el.getAttribute("aria-valuenow") || null;
    return null;
  }

  function applyStates(el, role, tag, node, ctx) {
    const type = tag === "input" ? (el.type || "").toLowerCase() : "";
    if (type === "checkbox" || type === "radio") {
      if (type === "checkbox" && el.indeterminate) node.checked = "mixed";
      else if (el.checked) node.checked = true;
    } else if (CHECKED_ROLES.has(role)) {
      const checked = (el.getAttribute("aria-checked") || "").toLowerCase();
      if (checked === "true") node.checked = true;
      else if (checked === "mixed") node.checked = "mixed";
    }
    if (node.act && isDisabled(el)) node.disabled = true;
    const expanded = el.getAttribute("aria-expanded");
    if (expanded === "true") node.expanded = true;
    else if (expanded === "false") node.expanded = false;
    else if (tag === "summary" && el.parentElement && tagOf(el.parentElement) === "details") node.expanded = !!el.parentElement.open;
    const pressed = (el.getAttribute("aria-pressed") || "").toLowerCase();
    if (pressed === "true") node.pressed = true;
    else if (pressed === "mixed") node.pressed = "mixed";
    if (tag === "option") {
      if (el.selected) node.selected = true;
    } else if (SELECTED_ROLES.has(role) && el.getAttribute("aria-selected") === "true") node.selected = true;
    if ((["input", "select", "textarea"].includes(tag) && el.required) || el.getAttribute("aria-required") === "true") node.required = true;
    const invalid = el.getAttribute("aria-invalid");
    if ((invalid && invalid !== "false") || isUserInvalid(el)) node.invalid = true;
    if (((tag === "input" && !NOT_READONLY_INPUTS.has(type)) || tag === "textarea") && el.readOnly) node.readonly = true;
    else if (el.getAttribute("aria-readonly") === "true") node.readonly = true;
    if (role === "heading") {
      const level = /^h[1-6]$/.test(tag) ? Number(tag[1]) : Number(el.getAttribute("aria-level")) || 2;
      node.level = level;
    } else if (el.hasAttribute("aria-level") && Number(el.getAttribute("aria-level")) >= 1) {
      node.level = Number(el.getAttribute("aria-level"));
    }
    if (ctx.focus === el) node.focused = true;
  }

  // ---------------------------------------------------------------------------
  // The page-read budget (classic page-agent.js, same constants). A hostile
  // page can hold millions of nodes (or make each one slow to read), and a
  // read runs on the page's main thread before any output limit applies.
  // Every read that sends page-controlled values to the session reads at
  // most MAX_NODES nodes and returns at most MAX_SIZE characters (values, and
  // NODE_SIZE for each node's keys), for MAX_WALK_MS (under the host's 10 s
  // frame timeout, so an inner frame answers cut instead of timing out);
  // past any of them it stops and says why (`truncated`: "nodes", "size" or
  // "time"), and the session prints a note (core.readCutNote). A caller can
  // lower a bound, never raise it. `spend`, `chargeSize` and `fit` charge it.
  const now = () => (global.performance && global.performance.now ? global.performance.now() : Date.now());
  const MAX_NODES = 250000;
  const MAX_WALK_MS = 8000;
  const MAX_SIZE = 2000000;
  const NODE_SIZE = 32;
  function readBudget(opts) {
    const o = opts || {};
    const nodes = Math.min(MAX_NODES, o.maxNodes > 0 ? Math.floor(o.maxNodes) : MAX_NODES);
    const size = Math.min(MAX_SIZE, o.maxSize > 0 ? Math.floor(o.maxSize) : MAX_SIZE);
    return { left: nodes, sizeLeft: size, nodes, size, deadline: now() + MAX_WALK_MS, ticks: 0, truncated: undefined };
  }
  // The budget for page functions the runtime runs in this world
  // (agent-tools.js): A.budget(opts).
  function budget(opts) {
    const b = readBudget(opts);
    return {
      spend: (count) => spend(b, count === undefined ? 1 : count),
      charge: (count) => chargeSize(b, count),
      fit: (s) => fit(b, s),
      // `s` cut where the budget ends, before the caller normalizes it.
      head: (s) => head(b, s),
      // The characters left to charge, so a caller can refuse work (such as
      // parsing a URL) on a value fit would cut anyway.
      get sizeLeft() {
        return b.sizeLeft;
      },
      // `s` with its cuts settled, for a page function that cuts or
      // searches its own text before it replies (sealing settles the rest).
      settle: (s) => settleCuts(s),
      // The bounded DOM reads, charged to this budget.
      textContent: (node) => boundedTextContent(node, b),
      innerText: (el) => boundedInnerText(el, b),
      outerHTML: (el) => boundedHTML(el, b, true),
      innerHTML: (el) => boundedHTML(el, b, false),
      get truncated() {
        return b.truncated;
      },
      // What the session needs for its note and for the budget it passes on.
      report: () => ({ visited: b.nodes - b.left, size: b.size - b.sizeLeft, maxNodes: b.nodes, maxSize: b.size, truncated: b.truncated }),
    };
  }
  // Reading the clock every node costs; every 256th is enough.
  function spend(ctx, count) {
    if (ctx.truncated) return false;
    if (ctx.left < count) {
      ctx.truncated = "nodes";
      return false;
    }
    ctx.left -= count;
    if (++ctx.ticks % 256 === 0 && now() > ctx.deadline) {
      ctx.truncated = "time";
      return false;
    }
    return true;
  }
  function chargeSize(ctx, count) {
    if (ctx.sizeLeft >= count) {
      ctx.sizeLeft -= count;
      return true;
    }
    ctx.sizeLeft = 0;
    if (!ctx.truncated) ctx.truncated = "size";
    return false;
  }
  // `s` charged to the size budget, cut where the budget ends (CUT, which
  // sealing turns into "…" well before the cut).
  function fit(ctx, s) {
    if (typeof s !== "string" || !s) return s;
    const left = ctx.sizeLeft;
    if (chargeSize(ctx, s.length)) return s;
    let end = left;
    // Never split a surrogate pair.
    if (end > 0 && /[\ud800-\udbff]/.test(s[end - 1])) end--;
    return s.slice(0, end) + CUT;
  }
  // `s` cut where the size budget ends, before the caller normalizes or
  // parses it (normalizing only shortens a string); not charged, `fit`
  // charges what the caller keeps. A cut leaves CUT and stops the read
  // ("size"), as `fit` does.
  function head(ctx, s) {
    if (typeof s !== "string" || s.length <= ctx.sizeLeft) return s;
    if (!ctx.truncated) ctx.truncated = "size";
    let end = ctx.sizeLeft;
    if (end > 0 && /[\ud800-\udbff]/.test(s[end - 1])) end--;
    return s.slice(0, end) + CUT;
  }
  // `read` (a bounded DOM read, `read(node, budget)`) of `node` within what
  // `ctx` has left: its nodes charged to `ctx`, and a read it cut stops `ctx`
  // too. Characters are charged when the caller fits what it keeps.
  function readWithin(ctx, read, node) {
    const b = readBudget({ maxNodes: Math.max(1, ctx.left), maxSize: Math.max(1, ctx.sizeLeft) });
    const text = read(node, b);
    spend(ctx, b.nodes - b.left);
    if (b.truncated && !ctx.truncated) ctx.truncated = b.truncated;
    return text;
  }
  // Visits `root` and its descendants in tree order: enter(node) before a
  // node's children (false skips them, STOP ends the walk), leave(node)
  // after them. `templates`: a <template>'s content counts as its children.
  // Iterative: a page can nest elements deeper than the stack.
  const STOP = {};
  function walkTree(root, enter, leave, templates) {
    const outs = [];
    let n = root;
    for (;;) {
      const r = enter(n);
      if (r === STOP) return;
      let child = null;
      if (r !== false) {
        if (templates && n.nodeType === 1 && tagOf(n) === "template" && n.content) {
          child = n.content.firstChild;
          if (child) outs.push(n);
        } else child = n.firstChild;
      }
      if (child) {
        n = child;
        continue;
      }
      for (;;) {
        if (leave && leave(n) === STOP) return;
        if (n === root) return;
        if (n.nextSibling) {
          n = n.nextSibling;
          break;
        }
        let p = n.parentNode;
        if (outs.length && (!p || p === outs[outs.length - 1].content)) p = outs.pop();
        if (!p) return;
        n = p;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Bounded DOM reads. A DOM getter (textContent, innerText, outerHTML)
  // builds its whole string before anything can cut it, and a hostile
  // page sets how large that is. These read within a page-read budget `b`:
  // first a counting walk (nodes, and the lengths of the strings the getter
  // would join, read without copying them), stopped at what `b` has left;
  // when the getter's string fits, the getter runs and the string is
  // charged (exact text); else the string is built node by node and stops
  // where the budget does (`b.truncated` says why). Walks are iterative.
  // What a getter of `kind` ("text": textContent, "inner": innerText,
  // "html": innerHTML/outerHTML) would read under `root`: { nodes, size,
  // depth } within `limits` ({ nodes, size, depth, deadline }), else
  // { over: "nodes" | "size" | "time" | "depth" }. Attributes count as
  // nodes; the size of HTML adds tags and attributes.
  function measureTree(root, kind, limits) {
    let nodes = 0;
    let size = 0;
    let depth = 0;
    let deepest = 0;
    let over = null;
    walkTree(root, (n) => {
      if (++nodes > limits.nodes) return (over = "nodes"), STOP;
      if ((nodes & 255) === 0 && now() > limits.deadline) return (over = "time"), STOP;
      const t = n.nodeType;
      if (t === 3 || t === 4) size += n.data.length;
      else if (t === 8 || t === 7) size += kind === "html" ? n.data.length + 7 : 0;
      else if (t === 1) {
        if (kind === "html") {
          const attrs = n.attributes;
          nodes += attrs.length;
          if (nodes > limits.nodes) return (over = "nodes"), STOP;
          size += 2 * n.tagName.length + 5;
          for (let i = 0; i < attrs.length; i++) size += attrs[i].name.length + attrs[i].value.length + 4;
        } else if (kind === "inner") size += 2;
        if (++depth > deepest) deepest = depth;
        if (deepest > limits.depth) return (over = "depth"), STOP;
      }
      if (size > limits.size) return (over = "size"), STOP;
      return kind === "html" || t === 1 || t === 9 || t === 11;
    }, (n) => {
      if (n.nodeType === 1) depth--;
    }, kind === "html");
    return over ? { over } : { nodes, size, depth: deepest };
  }
  // How far a getter's result may run past the counted size: escaping
  // grows HTML, innerText adds line breaks. A result past it is still cut.
  function readLimits(b) {
    return { nodes: b.left, size: b.sizeLeft, depth: Infinity, deadline: b.deadline };
  }
  // textContent: every Text descendant's data, in order.
  function boundedTextContent(node, b) {
    const t = node.nodeType;
    if (t === 3 || t === 4 || t === 7 || t === 8) return spend(b, 1) ? fit(b, node.data) : "";
    if (t === 9 || t === 10) return null;
    const m = measureTree(node, "text", readLimits(b));
    if (!m.over) {
      spend(b, m.nodes);
      return fit(b, node.textContent);
    }
    const parts = [];
    walkTree(node, (n) => {
      if (!spend(b, 1)) return STOP;
      if (n.nodeType === 3 || n.nodeType === 4) {
        parts.push(fit(b, n.data));
        if (b.truncated) return STOP;
      }
      return n.nodeType === 1 || n.nodeType === 11;
    });
    return parts.join("");
  }
  // innerText: past the budget, an approximation of the rendered text (no
  // hidden, script or style content; a line break around each block and
  // at each <br>) that stops at the budget.
  const NO_INNER_TEXT = new Set(["script", "style", "template", "noscript", "head", "title", "meta", "link"]);
  function boundedInnerText(el, b) {
    const m = measureTree(el, "inner", readLimits(b));
    if (!m.over) {
      spend(b, m.nodes);
      return fit(b, el.innerText);
    }
    const parts = [];
    const blocks = [];
    walkTree(el, (n) => {
      if (!spend(b, 1)) return STOP;
      if (n.nodeType === 3 || n.nodeType === 4) {
        parts.push(fit(b, head(b, n.data).replace(/[ \t\r\n]+/g, " ")));
        return b.truncated ? STOP : true;
      }
      if (n.nodeType !== 1) return false;
      const tag = tagOf(n);
      if (NO_INNER_TEXT.has(tag)) return false;
      if (tag === "br") {
        parts.push(fit(b, "\n"));
        return false;
      }
      const style = styleOf(n);
      if (!style || style.display === "none") return false;
      const block = n !== el && !/^inline/.test(style.display) && style.display !== "contents";
      if (block) parts.push(fit(b, "\n"));
      blocks.push(block);
      return true;
    }, (n) => {
      if (n.nodeType === 1 && n !== el && blocks.length && blocks.pop()) parts.push(fit(b, "\n"));
    });
    return parts.join("").replace(/ *\n */g, "\n").replace(/\n{3,}/g, "\n\n").replace(/^\n+|\n+$/g, "");
  }
  // innerHTML (`outer` false) or outerHTML: past the budget, the HTML
  // fragment serialization algorithm, node by node, stopped at the budget.
  const VOID_TAGS = new Set(["area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr"]);
  const RAW_TEXT_TAGS = new Set(["style", "script", "xmp", "iframe", "noembed", "noframes", "plaintext", "noscript"]);
  const FOREIGN_NS = new Set([HTML_NS, "http://www.w3.org/2000/svg", "http://www.w3.org/1998/Math/MathML"]);
  const escapeText = (s) => s.replace(/&/g, "&amp;").replace(/\u00a0/g, "&nbsp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const escapeAttr = (s) => s.replace(/&/g, "&amp;").replace(/\u00a0/g, "&nbsp;").replace(/"/g, "&quot;");
  function attrName(a) {
    if (!a.namespaceURI) return a.localName;
    if (a.namespaceURI === "http://www.w3.org/XML/1998/namespace") return "xml:" + a.localName;
    if (a.namespaceURI === "http://www.w3.org/2000/xmlns/") return a.localName === "xmlns" ? "xmlns" : "xmlns:" + a.localName;
    if (a.namespaceURI === "http://www.w3.org/1999/xlink") return "xlink:" + a.localName;
    return a.name;
  }
  function boundedHTML(el, b, outer) {
    const m = measureTree(el, "html", readLimits(b));
    if (!m.over) {
      spend(b, m.nodes);
      return fit(b, outer ? el.outerHTML : el.innerHTML);
    }
    const parts = [];
    const push = (s) => {
      parts.push(fit(b, s));
      return b.truncated ? STOP : true;
    };
    const tagName = (n) => (FOREIGN_NS.has(n.namespaceURI) ? n.localName : n.tagName);
    walkTree(el, (n) => {
      if (!spend(b, 1)) return STOP;
      if (n === el && !outer) return true;
      const t = n.nodeType;
      if (t === 3 || t === 4) {
        const p = n.parentNode;
        return push(p && p.nodeType === 1 && p.namespaceURI === HTML_NS && RAW_TEXT_TAGS.has(tagOf(p)) ? n.data : escapeText(n.data)) === STOP ? STOP : false;
      }
      if (t === 8) return push(`<!--${n.data}-->`) === STOP ? STOP : false;
      if (t === 7) return push(`<?${n.target} ${n.data}>`) === STOP ? STOP : false;
      if (t !== 1) return false;
      const attrs = n.attributes;
      if (!spend(b, attrs.length)) return STOP;
      let head = "<" + tagName(n);
      for (let i = 0; i < attrs.length; i++) head += ` ${attrName(attrs[i])}="${escapeAttr(attrs[i].value)}"`;
      if (push(head + ">") === STOP) return STOP;
      return !(n.namespaceURI === HTML_NS && VOID_TAGS.has(tagOf(n)));
    }, (n) => {
      if (n.nodeType !== 1 || (n === el && !outer)) return;
      if (n.namespaceURI === HTML_NS && VOID_TAGS.has(tagOf(n))) return;
      return push(`</${tagName(n)}>`);
    }, true);
    return parts.join("");
  }
  // A string read whole by the page (an attribute, a field's value),
  // charged and cut.
  function boundedString(s, b) {
    if (typeof s !== "string") return s;
    return spend(b, 1) ? fit(b, s) : "";
  }


  // The reply budget. Every reply this world sends to the session passes
  // through `reply`: the runtime wraps each agent-world call in it
  // (runtime-core.js, Frame._call) and the host's frame.observe script runs
  // each read inside it, so a method or page function added here cannot
  // reply around it. Past `limit` characters of JSON (at most MAX_REPLY) the
  // reply becomes a cut marker, which the runtime turns into an error worded
  // by core.readCutNote, as every read cut at its budget. A caller can lower
  // the limit, never raise it. The default is what a read within the
  // page-read budget can return: MAX_SIZE characters of values and NODE_SIZE
  // of keys for each of MAX_NODES nodes. Sealing also settles every cut the
  // reply's strings hold (settleCuts).
  const MAX_REPLY = MAX_SIZE + MAX_NODES * NODE_SIZE;
  const REPLY_CUT = "__cmuxReplyCut";
  // The reply of a method that stopped at its budget before it had all its
  // answer: the runtime fails the call with core.readCutNote's words, as
  // for a reply past the reply budget. `cut` is { truncated, maxNodes, maxSize }.
  const cutReply = (cut) => ({ [REPLY_CUT]: cut });
  // The characters of JSON `value` takes, counted until they pass `max`.
  // Iterative, and it stops there, so measuring costs at most the limit.
  function replySize(value, max) {
    let size = 0;
    const stack = [value];
    while (stack.length && size <= max) {
      const v = stack.pop();
      if (typeof v === "string") size += v.length + 2;
      else if (v === null || v === undefined || typeof v !== "object") size += typeof v === "function" ? 0 : 8;
      else if (Array.isArray(v)) {
        size += 2 + v.length;
        for (let i = 0; i < v.length && size <= max; i++) stack.push(v[i]);
      } else {
        size += 2;
        for (const key of Object.keys(v)) {
          size += key.length + 4;
          stack.push(v[key]);
          if (size > max) break;
        }
      }
    }
    return size;
  }
  // Settles every cut in `value`'s strings (settleCuts), in place.
  function settleReply(value) {
    if (typeof value === "string") return settleCuts(value);
    const stack = [value];
    while (stack.length) {
      const v = stack.pop();
      if (v === null || typeof v !== "object") continue;
      for (const key of Array.isArray(v) ? v.keys() : Object.keys(v)) {
        const item = v[key];
        if (typeof item === "string") {
          if (item.indexOf(CUT) !== -1) v[key] = settleCuts(item);
        } else if (item !== null && typeof item === "object") stack.push(item);
      }
    }
    return value;
  }
  function sealReply(value, limit) {
    const max = Math.min(MAX_REPLY, typeof limit === "number" && limit >= 0 ? Math.floor(limit) : MAX_REPLY);
    if (replySize(value, max) <= max) return settleReply(value);
    return cutReply({ truncated: "size", maxSize: max });
  }
  function reply(value, limit) {
    return value instanceof Promise ? value.then((v) => sealReply(v, limit)) : sealReply(value, limit);
  }

  // The walk descends at most MAX_DEPTH elements, over the whole stitched
  // tree (classic's bound: a frame's walk starts at its iframe's depth,
  // `opts.nest`); a deeper element prints as a generic with a ref and
  // NEST_CUT. The walk is iterative, because a page can nest elements deeper
  // than the renderer's stack (Chromium overflows between 700 and 900
  // levels of a recursive walk): `ctx.work` holds the steps still to run,
  // and each step runs exactly where the recursive walk would have run it
  // (a node's children and what follows them are pushed in reverse, so the
  // first child's whole subtree runs before the second child).
  const MAX_DEPTH = 1000;
  const NEST_CUT = `nested deeper than ${MAX_DEPTH} elements; snapshot this ref to read it`;
  // The page-read budget on the work stack: a node is charged where it is
  // scheduled (a node's children are pushed before any is read, so one
  // element with a million children would otherwise push a million steps),
  // and once the budget stops the walk the scheduled visits return at once
  // while the steps that close nodes still run.
  const later = (ctx, step) => ctx.work.push(step);
  // Past the node budget a node already charged is still read (it was
  // scheduled within the budget; it can schedule nothing more); past the
  // size budget or the time, the walk stops.
  const stopped = (ctx) => !!ctx.truncated && ctx.truncated !== "nodes";
  function runWork(ctx) {
    const work = ctx.work;
    while (work.length) work.pop()();
  }

  function visitNode(n, out, ctx, parentVisible, parentAriaHidden, skipText) {
    if (stopped(ctx) || ctx.visited.has(n)) return;
    ctx.visited.add(n);
    if (n.nodeType === 3) {
      if ((parentVisible || ctx.showHidden) && !skipText && n.nodeValue) out.push(fit(ctx, n.nodeValue));
      return;
    }
    if (n.nodeType !== 1) return;
    if (ctx.nest >= MAX_DEPTH) {
      out.push({ role: "generic", ref: refFor(n), unread: NEST_CUT });
      return;
    }
    ctx.nest++;
    later(ctx, () => ctx.nest--);
    visitElement(n, out, ctx, parentAriaHidden, skipText);
  }

  // Writes the ::before text now and schedules the children, the owned
  // elements and the ::after text, in that order.
  // Every child looked at is charged before it is scheduled; the list
  // stops where the budget does.
  function visitChildren(el, out, ctx, visible, ariaHidden, skipText) {
    if (stopped(ctx)) return;
    if (visible && !skipText) out.push(fit(ctx, pseudoText(el, "::before")));
    const kids = [];
    const assigned = tagOf(el) === "slot" ? el.assignedNodes() : [];
    if (assigned.length) {
      for (let i = 0; i < assigned.length && spend(ctx, 1); i++) kids.push(assigned[i]);
    } else {
      for (let child = el.firstChild; child && spend(ctx, 1); child = child.nextSibling) {
        if (!child.assignedSlot) kids.push(child);
      }
      if (el.shadowRoot) {
        for (let child = el.shadowRoot.firstChild; child && spend(ctx, 1); child = child.nextSibling) kids.push(child);
      }
    }
    // Each id in aria-owns is charged, also one that names a node already
    // read: the page sets how many there are.
    const owns = el.getAttribute("aria-owns");
    if (owns) {
      const ids = /\S+/g;
      for (let m = ids.exec(owns); m && spend(ctx, 1); m = ids.exec(owns)) {
        const owned = el.ownerDocument.getElementById(m[0]);
        if (owned && owned !== el) kids.push(owned);
      }
    }
    if (visible && !skipText) later(ctx, () => stopped(ctx) || out.push(fit(ctx, pseudoText(el, "::after"))));
    for (let i = kids.length - 1; i >= 0; i--) {
      const child = kids[i];
      later(ctx, () => visitNode(child, out, ctx, visible, ariaHidden, skipText));
    }
  }

  // Clipping by overflow. An element that lies entirely outside the box of
  // an ancestor with `overflow: hidden|clip` (per axis) or `contain: paint`
  // cannot be seen (Amazon's overflowing nav belt, GitHub's ellipsized
  // commit links). Clips follow CSS containing blocks: an absolutely
  // positioned element escapes clippers below its nearest positioned
  // ancestor, a fixed one escapes all but those at or above a transformed
  // ancestor. The root and body clip the viewport, not a box, so they do not
  // count; scroll containers do not either (their content is reachable).
  const INTERACTIVE_SELECTOR = "a[href], area[href], button, input:not([type=hidden]), select, textarea, summary, " +
    "[tabindex]:not([tabindex='-1']), [contenteditable=''], [contenteditable=true], [role=button], [role=link], " +
    "[role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=option], [role=switch], [role=combobox], [role=textbox]";
  const CLIPPING = new Set(["hidden", "clip"]);
  const EMPTY_CLIPS = [];
  function clipRectOf(el, style) {
    const x = CLIPPING.has(style.overflowX);
    const y = CLIPPING.has(style.overflowY);
    const paint = /\b(paint|strict|content)\b/.test(style.contain || "");
    if (!x && !y && !paint) return null;
    const r = el.getBoundingClientRect();
    const left = r.left + el.clientLeft;
    const top = r.top + el.clientTop;
    return {
      left: x || paint ? left : -Infinity,
      right: x || paint ? left + (el.clientWidth || r.width) : Infinity,
      top: y || paint ? top : -Infinity,
      bottom: y || paint ? top + (el.clientHeight || r.height) : Infinity,
    };
  }
  const overlaps = (r, c) => r.right > c.left + 0.5 && r.left < c.right - 0.5 && r.bottom > c.top + 0.5 && r.top < c.bottom - 0.5;

  function visitElement(el, out, ctx, parentAriaHidden, skipText) {
    const tag = tagOf(el);
    if (SKIP_TAGS.has(tag)) return;
    const style = styleOf(el);
    if (!style || ctx.showHidden || style.display === "none") return visitElementBox(el, tag, style, out, ctx, parentAriaHidden, skipText);
    const saved = [ctx.clips, ctx.positioned, ctx.transformed];
    ctx.depth++;
    // Runs after the element's subtree (or at once, after an early return).
    later(ctx, () => {
      ctx.depth--;
      [ctx.clips, ctx.positioned, ctx.transformed] = saved;
    });
    const position = style.position;
    if (position === "fixed") ctx.clips = ctx.clips.filter((c) => c.depth <= ctx.transformed);
    else if (position === "absolute") ctx.clips = ctx.clips.filter((c) => c.depth <= ctx.positioned);
    if ((ctx.clips.length || ctx.viewport) && style.display !== "contents") {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) {
        for (const c of ctx.clips) {
          if (!overlaps(r, c.rect)) {
            out.push(DROPPED);
            return;
          }
        }
        if (ctx.viewport && !overlaps(r, ctx.viewport)) {
          ctx.offscreen += el.querySelectorAll(INTERACTIVE_SELECTOR).length + (el.matches(INTERACTIVE_SELECTOR) ? 1 : 0);
          return;
        }
      }
    }
    const transform = style.transform !== "none" || style.filter !== "none" || /\b(paint|strict|content|layout)\b/.test(style.contain || "");
    if (position !== "static" || transform) ctx.positioned = ctx.depth;
    if (transform) ctx.transformed = ctx.depth;
    if (tag !== "html" && tag !== "body") {
      const rect = clipRectOf(el, style);
      if (rect) ctx.clips = ctx.clips.concat({ rect, depth: ctx.depth });
    }
    visitElementBox(el, tag, style, out, ctx, parentAriaHidden, skipText);
  }

  function visitElementBox(el, tag, style, out, ctx, parentAriaHidden, skipText) {
    const ariaHidden = parentAriaHidden || el.getAttribute("aria-hidden") === "true";
    const rendered = !ariaHidden && isRendered(el, style);
    if (!rendered && !ctx.showHidden) return;
    const visible = rendered && style.visibility === "visible";
    // content-visibility:hidden keeps the element's box and skips its
    // contents, so nothing in it can be seen.
    if (rendered && !ctx.showHidden && skipsContents(style)) return;
    if (!visible && !ctx.showHidden) {
      // A visibility:hidden parent can still hold visible children.
      visitChildren(el, out, ctx, false, ariaHidden, skipText);
      return;
    }
    const role = roleOf(el);
    const interactive = isInteractive(el, role, style);
    const scrollable = isScrollable(el, style);
    // A hidden paragraph (showHidden) keeps its node so it can say [hidden].
    const flattens = FLATTEN_ROLES.has(role) && !(role === "paragraph" && !visible);
    const flattenable = flattens || FLATTEN_UNNAMED_ROLES.has(role);
    const name = flattens && !interactive && !scrollable ? "" : nodeName(el, role, !visible);
    if (!interactive && !scrollable && (flattens || (flattenable && !name))) {
      if (role === "img" || role === "image") return;
      // Unrendered content (showHidden) has no layout; keep it apart.
      const block = isBlock(style, tag) || !rendered;
      if (block) out.push(BREAK);
      // A <label>'s own text is its control's name, printed on the control.
      const labelText = tag === "label" && el.control;
      if (block) later(ctx, () => out.push(BREAK));
      visitChildren(el, out, ctx, visible, ariaHidden, skipText || !!labelText);
      return;
    }
    // A link or button with an empty box shows nothing unless some content
    // inside it has a box (Wikipedia's zero-width "Jump up" backlinks).
    if ((role === "link" || role === "button") && visible && !ctx.showHidden && !hasVisibleBox(el)) return;
    const node = { role };
    chargeSize(ctx, NODE_SIZE);
    if (name) node.name = fit(ctx, name);
    if (interactive || scrollable) node.act = 1;
    if (interactive || scrollable || role === "iframe" || (name && SCOPE_ROLES.has(role))) {
      node.ref = refFor(el);
      // On screen: the host keeps these when it condenses a large snapshot.
      if (visible && overlaps(el.getBoundingClientRect(), ctx.screen)) node.vp = 1;
    }
    if (!visible) node.hidden = 1;
    if (scrollable) node.scrollable = 1;
    applyStates(el, role, tag, node, ctx);
    if (role === "iframe") {
      node.frame = handleFor(el);
      if (ctx.focus === el) node.frameFocused = 1;
      delete node.focused;
      out.push(node);
      return;
    }
    const value = valueOf(el, role, tag);
    if (value !== null) node.value = fit(ctx, value);
    if (role === "link") {
      const url = displayUrl(el);
      if (url) node.url = fit(ctx, url);
      const offsite = offsiteSummary(el);
      if (offsite) node.offsite = fit(ctx, offsite);
    }
    const placeholder = el.getAttribute("placeholder");
    if (placeholder && normalize(placeholder) !== name && (tag === "input" || tag === "textarea")) node.placeholder = fit(ctx, normalize(placeholder));
    if (tag === "select") {
      const optionName = (o) => {
        chargeSize(ctx, NODE_SIZE);
        return fit(ctx, normalize(o.label || o.textContent));
      };
      const option = (o) => (o.selected ? { name: optionName(o), selected: true } : { name: optionName(o) });
      // A list box shows its options; a drop-down shows them on request. A
      // closed drop-down prints its first INLINE_OPTIONS and a count, so only
      // those cross to the host. Options listed whole count toward the node
      // budget; past it the list stops.
      const listed = (map) => {
        const all = el.options;
        const list = [];
        for (let i = 0; i < all.length && !ctx.truncated && spend(ctx, 1); i++) list.push(map(all[i]));
        return list;
      };
      if (el.multiple || el.size > 1) node.children = listed((o) => Object.assign({ role: "option" }, option(o)));
      else if (ctx.allOptions || node.expanded === true) node.options = listed(option);
      else {
        const all = el.options;
        node.options = [];
        for (let i = 0; i < all.length && i < INLINE_OPTIONS && !ctx.truncated; i++) node.options.push(option(all[i]));
        if (all.length > INLINE_OPTIONS) node.optionCount = all.length;
      }
    }
    if (!LEAF_TAGS.has(tag) && !isContentEditableHost(el)) {
      const kids = [];
      // The node goes out after its subtree, as its children.
      later(ctx, () => {
        const children = normalizeChildren(kids);
        if (children.length) node.children = children;
        out.push(node);
      });
      visitChildren(el, kids, ctx, visible, ariaHidden, false);
      return;
    }
    out.push(node);
  }

  // Joins text between structural breaks and collapses whitespace to single
  // spaces, so inline markup never doubles a space.
  function normalizeChildren(items) {
    const out = [];
    let buffer = "";
    const flush = () => {
      const text = normalize(buffer);
      if (text) out.push(text);
      buffer = "";
    };
    let closeBracket = null;
    for (let item of items) {
      if (item === DROPPED) {
        // "(#1234)" with the link left out would read "()".
        const open = /[(\[]\s*$/.exec(buffer);
        if (open) {
          buffer = buffer.slice(0, open.index);
          closeBracket = open[0][0] === "(" ? ")" : "]";
        }
        continue;
      }
      if (typeof item === "string" && closeBracket) {
        const trimmed = item.replace(/^\s*/, "");
        if (trimmed[0] === closeBracket) item = trimmed.slice(1);
        closeBracket = null;
      } else if (item !== BREAK) closeBracket = null;
      if (typeof item === "string") buffer += item;
      else if (item === BREAK) buffer += "\n\u0000";
      else {
        flush();
        out.push(item);
      }
    }
    flush();
    // A break splits a text run into separate lines.
    return out.flatMap((c) => (typeof c === "string" ? c.split("\u0000").map(normalize).filter(Boolean) : [c]));
  }

  // opts: { root: handle | null, showHidden, base, nest, maxNodes, maxSize }
  // -> { flat, max, offscreen, ms, visited, size, truncated: "nodes" | "time" | "size" | undefined }
  function snapshot(opts) {
    return withReadCaches(() => readSnapshot(opts || {}));
  }
  function readSnapshot(opts) {
    const started = now();
    raiseRefBase(opts.base);
    pruneRefs();
    pruneHandles();
    const root = opts.root ? element(opts.root) : document.body || document.documentElement;
    if (!root || !root.isConnected) throw agentError("stale", "The snapshot root was removed from the page");
    const ctx = Object.assign(readBudget(opts), {
      showHidden: !!opts.showHidden,
      focus: deepActiveElement(document),
      visited: new Set(),
      depth: 0,
      clips: EMPTY_CLIPS,
      positioned: -1,
      transformed: -1,
      viewport: opts.viewport ? { left: 0, top: 0, right: global.innerWidth, bottom: global.innerHeight } : null,
      screen: { left: 0, top: 0, right: global.innerWidth, bottom: global.innerHeight },
      allOptions: !!opts.options,
      offscreen: 0,
      // Elements above the root in the stitched tree (snapshot.js MAX_NEST).
      nest: Math.min(MAX_DEPTH, Math.max(0, Math.floor(Number(opts.nest)) || 0)),
      work: [],
    });
    // The label index charges this snapshot's budget.
    labelBudget = ctx;
    const out = [];
    if (spend(ctx, 1)) visitElement(root, out, ctx, false, false);
    runWork(ctx);
    const nodes = normalizeChildren(out);
    // `flat` is the tree in pre-order, [depth, node or text] per entry with
    // no `children`: a nested result deeper than about 300 levels fails
    // CDP's CBOR conversion (snapshot.js rebuilds the tree).
    // `ms` is the traversal time in this frame, for perf measurements.
    return { flat: flatten(nodes), max: refCounter, offscreen: ctx.offscreen, ms: now() - started, visited: ctx.nodes - ctx.left, size: ctx.size - ctx.sizeLeft, truncated: ctx.truncated };
  }

  function flatten(nodes) {
    const flat = [];
    const stack = [];
    for (let i = nodes.length - 1; i >= 0; i--) stack.push(0, nodes[i]);
    while (stack.length) {
      const item = stack.pop();
      const depth = stack.pop();
      flat.push([depth, item]);
      const children = typeof item === "string" ? null : item.children;
      if (!children) continue;
      delete item.children;
      for (let i = children.length - 1; i >= 0; i--) stack.push(depth + 1, children[i]);
    }
    return flat;
  }

  // Table sizes, for leak checks (tests/browser-parity/perf).
  function stats() {
    return { refs: refRegistry.size, handles: handles.size };
  }

  function refState(ref, base) {
    raiseRefBase(base);
    return { live: !!refElement(ref), max: refCounter };
  }

  function refForHandle(id, base) {
    raiseRefBase(base);
    return { ref: refFor(element(id)), max: refCounter };
  }

  // The topmost element at a viewport point, raised to its nearest control,
  // scrollable region or iframe so the ref is something an agent can act on.
  function elementAt(x, y, base) {
    return withReadCaches(() => readElementAt(x, y, base));
  }
  function readElementAt(x, y, base) {
    raiseRefBase(base);
    let el = document.elementFromPoint(x, y);
    while (el && el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    if (!el) return null;
    let target = el;
    for (let cur = el; cur && cur !== document.body && cur !== document.documentElement; cur = parentCrossingShadow(cur)) {
      const role = roleOf(cur);
      const style = styleOf(cur);
      if (role === "iframe" || isInteractive(cur, role, style) || isScrollable(cur, style)) {
        target = cur;
        break;
      }
    }
    if (roleOf(target) === "iframe") return { frame: handleFor(target), box: contentBox(handleFor(target)) };
    const r = target.getBoundingClientRect();
    return {
      ref: refFor(target),
      role: roleOf(target),
      name: accessibleName(target, false),
      box: { x: r.x, y: r.y, width: r.width, height: r.height },
      max: refCounter,
    };
  }

  if (injected) {
    injected._engines.set("aria-ref", {
      queryAll(root, selector) {
        const el = refElement(String(selector).trim());
        return el ? [el] : [];
      },
    });
  }


  // ---------------------------------------------------------------------------
  // Selectors and element state

  function requireInjected() {
    if (!injected) throw agentError("unsupported", "Playwright injected script is not installed");
    return injected;
  }

  function splitFrames(selector) {
    const parsed = requireInjected().parseSelector(selector);
    const isEnterFrame = (p) => p.name === "internal:control" && p.body === "enter-frame";
    if (!parsed.parts.some(isEnterFrame)) return [selector];
    // A parsed part's `source` omits the engine name except for CSS.
    const text = (p) => (p.name === "css" ? p.source : `${p.name}=${p.source}`);
    const hops = [];
    let parts = [];
    for (const part of parsed.parts) {
      if (isEnterFrame(part)) {
        hops.push(parts.map(text).join(" >> "));
        parts = [];
      } else {
        parts.push(part);
      }
    }
    hops.push(parts.map(text).join(" >> "));
    return hops;
  }

  // MAX_NODES handles (the page-read node budget): past that, a call
  // without a limit is cut, and a limit above it keeps the first MAX_NODES.
  function queryAll(selector, scopeHandle, limit) {
    const inj = requireInjected();
    const root = scopeHandle ? element(scopeHandle) : document;
    const parsed = inj.parseSelector(selector);
    const found = withReadCaches(() => inj.querySelectorAll(parsed, root));
    const asked = Number.isInteger(limit) && limit >= 0;
    if (!asked && found.length > MAX_NODES) return cutReply({ truncated: "nodes", maxNodes: MAX_NODES });
    return found.slice(0, asked ? Math.min(limit, MAX_NODES) : MAX_NODES).map(handleFor);
  }

  function describe(id) {
    return requireInjected().previewNode(element(id));
  }

  function strictError(selector, ids) {
    return requireInjected().strictModeViolationError(requireInjected().parseSelector(selector), ids.map(element)).message;
  }

  // Playwright checks "stable" over animation frames. WebKit runs no
  // animation frames while a document is still loading (a body that never
  // ends), so after a quarter second without a frame the check samples the
  // element's box on timers instead: nothing renders, so nothing can move.
  async function checkStates(id, states) {
    const inj = requireInjected();
    const el = element(id);
    if (!states.includes("stable")) {
      const result = await inj.checkElementStates(el, states);
      return result === undefined ? "done" : result;
    }
    let frameSeen = false;
    global.requestAnimationFrame(() => (frameSeen = true));
    const viaFrames = inj.checkElementStates(el, states).then((r) => (r === undefined ? "done" : r));
    const fallback = new Promise((resolve) => global.setTimeout(resolve, 250)).then(async () => {
      if (frameSeen) return viaFrames;
      if (!el.isConnected) return "error:notconnected";
      const box = () => { const r = el.getBoundingClientRect(); return [r.x, r.y, r.width, r.height].join(","); };
      const first = box();
      await new Promise((resolve) => global.setTimeout(resolve, 50));
      if (!el.isConnected) return "error:notconnected";
      if (box() !== first) return { missingState: "stable" };
      const rest = states.filter((s) => s !== "stable");
      const result = rest.length ? await inj.checkElementStates(el, rest) : undefined;
      return result === undefined ? "done" : result;
    });
    return Promise.race([viaFrames, fallback]);
  }

  function elementState(id, state) {
    return requireInjected().elementState(element(id), state);
  }

  function isInViewport(rect) {
    return rect.top >= 0 && rect.left >= 0 && rect.bottom <= global.innerHeight && rect.right <= global.innerWidth;
  }

  // True when a scroll container between the element and the viewport cuts
  // part of it off (a target inside a nested scroller).
  function clippedByScroller(el, rect) {
    for (let p = el.parentElement || (el.getRootNode() && el.getRootNode().host); p && p !== document.documentElement && p !== document.body; p = p.parentElement || (p.getRootNode() && p.getRootNode().host)) {
      if (p.scrollHeight <= p.clientHeight && p.scrollWidth <= p.clientWidth) continue;
      const cs = global.getComputedStyle(p);
      if (!/(auto|scroll|hidden|clip)/.test(cs.overflowX + " " + cs.overflowY)) continue;
      const r = p.getBoundingClientRect();
      if (rect.top < r.top - 0.5 || rect.bottom > r.bottom + 0.5 || rect.left < r.left - 0.5 || rect.right > r.right + 0.5) return true;
    }
    return false;
  }

  function scrollIntoViewIfNeeded(id) {
    const el = element(id);
    if (!el.isConnected) return "error:notconnected";
    const rect = el.getBoundingClientRect();
    if (isInViewport(rect) && !clippedByScroller(el, rect)) return "done";
    if (typeof el.scrollIntoViewIfNeeded === "function") el.scrollIntoViewIfNeeded(true);
    else el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    return "done";
  }

  function rectOf(id) {
    const el = element(id);
    if (!el.isConnected) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  }

  // Center of the first client rect that is visible in the viewport, as
  // Playwright picks the first clipped content quad.
  function clickPoint(id) {
    const el = element(id);
    if (!el.isConnected) return { error: "error:notconnected" };
    const w = global.innerWidth;
    const h = global.innerHeight;
    const rects = [...el.getClientRects()].filter((r) => r.width > 0 && r.height > 0);
    if (!rects.length) return { error: "error:notvisible" };
    for (const r of rects) {
      const left = Math.max(r.left, 0);
      const top = Math.max(r.top, 0);
      const right = Math.min(r.right, w);
      const bottom = Math.min(r.bottom, h);
      if (right - left > 0.99 && bottom - top > 0.99) return { x: (left + right) / 2, y: (top + bottom) / 2 };
    }
    return { error: "error:notinviewport" };
  }

  function hitTarget(id, point, behavior) {
    const inj = requireInjected();
    const el = inj.retarget(element(id), behavior || "button-link");
    if (!el || !el.isConnected) return "error:notconnected";
    const result = inj.expectHitTarget(point, el);
    return result === "done" ? "done" : result.hitTargetDescription;
  }

  // Chromium moves focus to a focusable element on mousedown; WebKit on macOS
  // does not focus buttons or links. The runtime calls this between mousedown
  // and mouseup so focus follows the Chromium (reference) model.
  function emulateClickFocus(id, before) {
    const el = element(id);
    if (!el.isConnected) return false;
    const doc = el.ownerDocument;
    const active = doc.activeElement;
    if (before !== undefined && active !== (before ? handleElement(before) : doc.body) && active !== doc.body) return false;
    const target = el.closest("button, a[href], summary, input, select, textarea, [tabindex], [contenteditable=true], iframe");
    if (!target || target === active) return false;
    if (target.matches(":disabled")) return false;
    target.focus({ preventScroll: true });
    return doc.activeElement === target;
  }

  // The file input whose click (user, driver or page script `input.click()`)
  // most recently happened; WebKit does not say which input opened a chooser,
  // and `document.activeElement` is the button when a page opens a hidden input.
  let lastFileInput = null;
  document.addEventListener(
    "click",
    (event) => {
      const target = event.target;
      if (target instanceof HTMLInputElement && target.type === "file") lastFileInput = target;
    },
    true,
  );

  // The element that opened the current file chooser: the last clicked file
  // input while it is connected, else the focused element.
  function chooserHandle() {
    if (lastFileInput && lastFileInput.isConnected) return handleFor(lastFileInput);
    return activeHandle();
  }

  function activeHandle() {
    const active = document.activeElement;
    return active && active !== document.body ? handleFor(active) : null;
  }

  function fill(id, value) {
    return requireInjected().fill(element(id), value);
  }
  function selectText(id) {
    return requireInjected().selectText(element(id));
  }
  function focus(id, resetSelection) {
    return requireInjected().focusNode(element(id), resetSelection);
  }
  function blur(id) {
    return requireInjected().blurNode(element(id));
  }
  function selectOptions(id, options) {
    const inj = requireInjected();
    const resolved = options.map((o) => (o && o.handle ? element(o.handle) : o));
    return inj.selectOptions(element(id), resolved);
  }
  function dispatchEvent(id, type, init) {
    requireInjected().dispatchEvent(element(id), type, init || {});
    return "done";
  }
  function retargetHandle(id, behavior) {
    const el = requireInjected().retarget(element(id), behavior);
    return el ? handleFor(el) : null;
  }

  function read(id, what, arg) {
    const el = element(id);
    switch (what) {
      case "textContent":
        return el.textContent;
      case "innerText":
        if (!(el instanceof global.HTMLElement)) throw agentError("invalid", "Node is not an HTMLElement");
        return el.innerText;
      case "innerHTML":
        return el.innerHTML;
      case "getAttribute":
        return el.getAttribute(arg);
      case "inputValue": {
        const target = requireInjected().retarget(el, "follow-label");
        const tag = target ? tagOf(target) : "";
        if (!["input", "textarea", "select"].includes(tag)) {
          throw agentError("invalid", "Node is not an <input>, <textarea> or <select> element");
        }
        return target.value;
      }
      case "tagName":
        return el.tagName;
      case "isFileInput":
        return tagOf(el) === "input" && (el.type || "").toLowerCase() === "file";
      case "multiple":
        return !!el.multiple;
      default:
        throw agentError("invalid", `Unknown read ${what}`);
    }
  }

  function iframeHandles() {
    const out = [];
    const walk = (root) => {
      for (const el of root.querySelectorAll("*")) {
        const tag = tagOf(el);
        if (tag === "iframe" || tag === "frame") out.push(handleFor(el));
        if (el.shadowRoot) walk(el.shadowRoot);
      }
    };
    walk(document);
    return out;
  }

  // Content box of an <iframe> in this frame's viewport coordinates.
  function contentBox(id) {
    const el = element(id);
    const r = el.getBoundingClientRect();
    const cs = styleOf(el);
    const px = (v) => parseFloat(v) || 0;
    const left = r.left + el.clientLeft + px(cs && cs.paddingLeft);
    const top = r.top + el.clientTop + px(cs && cs.paddingTop);
    const width = el.clientWidth - px(cs && cs.paddingLeft) - px(cs && cs.paddingRight);
    const height = el.clientHeight - px(cs && cs.paddingTop) - px(cs && cs.paddingBottom);
    return { x: left, y: top, width, height };
  }

  // ---------------------------------------------------------------------------
  // Annotated screenshots: boxes and labels in a closed shadow root that is
  // removed right after capture. `refs` are [localRef, label] pairs.

  let overlay = null;
  function annotate(refs) {
    clearAnnotations();
    const host = document.createElement("cmux-annotations");
    host.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483647;display:block";
    const root = host.attachShadow({ mode: "closed" });
    let drawn = 0;
    for (const [ref, label] of refs) {
      const el = refElement(ref);
      if (!el) continue;
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      if (r.bottom < 0 || r.right < 0 || r.top > global.innerHeight || r.left > global.innerWidth) continue;
      const box = document.createElement("div");
      box.style.cssText = `position:fixed;left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px;` +
        "border:2px solid #e5007a;box-sizing:border-box";
      const tag = document.createElement("div");
      tag.textContent = label;
      tag.style.cssText = `position:fixed;left:${r.left}px;top:${Math.max(0, r.top - 14)}px;background:#e5007a;` +
        "color:#fff;font:bold 10px/14px monospace;padding:0 3px";
      root.append(box, tag);
      drawn++;
    }
    (document.body || document.documentElement).appendChild(host);
    overlay = host;
    return drawn;
  }
  function clearAnnotations() {
    if (overlay) overlay.remove();
    overlay = null;
    return "done";
  }

  const agent = {
    version: 2,
    ping: () => "pong",
    handleFor,
    element,
    snapshot,
    stats,
    refState,
    refForHandle,
    elementAt,
    splitFrames,
    queryAll,
    describe,
    strictError,
    checkStates,
    elementState,
    scrollIntoViewIfNeeded,
    rect: rectOf,
    clickPoint,
    hitTarget,
    emulateClickFocus,
    activeHandle,
    chooserHandle,
    fill,
    selectText,
    focus,
    blur,
    selectOptions,
    dispatchEvent,
    retarget: retargetHandle,
    read,
    iframeHandles,
    contentBox,
    annotate,
    clearAnnotations,
    budget,
    reply,
    injected,
    adoptClosedRoot,
  };
  Object.defineProperty(global, KEY, { value: agent, enumerable: false, configurable: true, writable: false });
  // The drivers resolve handles for input.setFiles through this name, and
  // the CDP driver names a file chooser's input with handleFor.
  Object.defineProperty(global, "__cmuxPageAgent", {
    value: { resolveHandle: (id) => handleElement(id), handleFor },
    enumerable: false,
    configurable: true,
    writable: false,
  });
})(
  globalThis,
  typeof __cmuxInjectedScriptFactory !== "undefined" ? __cmuxInjectedScriptFactory : null,
  // Playwright's role, name and hidden-state caches (its own snapshot and
  // getByRole turn them on while the DOM cannot change). The install recipe
  // puts the injected script's top-level functions in this scope.
  typeof beginAriaCaches === "function" && typeof endAriaCaches === "function" ? { begin: beginAriaCaches, end: endAriaCaches } : null,
);
