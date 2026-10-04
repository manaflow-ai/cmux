// Agent tools for the cmux browser REPL
// (plans/cmux-next/browser-repl/README.md): the tools, browser profile and
// agent features that a REPL-driving agent can use, in this
// REPL's Playwright-shaped API and without a model inside cmux.
//
// Globals: secret(name), secrets, search(query, options), tools.
// session: allowedDomains, prohibitedDomains, blockIPAddresses,
//   blockedNavigations, storageState, setStorageState, downloads, record.
// Page: markdown, extract, searchText, scrollToText, scroll, scrollInfo,
//   dropdownOptions, highlight, hideHighlight; locator.highlight.
//
// The runtime calls the hooks below through session.agentTools
// (runtime-core.js Session.call, its event router and Page._afterAction).
// The domain policy, the secret vault, TOTP, masking and capture masking are
// the host's (plans/cmux-next/browser-host.md section 4): this file only
// calls host.secrets(op) and host.policy(op) and passes secret handles on.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  const core = ns.core;
  const { Buffer } = core;
  const AGENT = 'globalThis[Symbol.for("cmux.browserRepl.agent")]';

  // ---------------------------------------------------------------------------
  // Domain patterns: "example.com" (and www.example.com),
  // "*.example.com" (subdomains and the bare domain), "http*://example.com",
  // "https://example.com", "*". A port in the pattern must match. Multiple
  // wildcards, wildcard TLDs and embedded wildcards are refused when set.

  // Host names as the policy compares them: lower case, no trailing dot,
  // internationalized labels in Punycode, as the host's domain policy does.
  function punycode(input) {
    const cps = [...input].map((c) => c.codePointAt(0));
    let out = cps.filter((c) => c < 0x80).map((c) => String.fromCharCode(c)).join("");
    const basic = out.length;
    let handled = basic;
    if (basic) out += "-";
    let n = 128;
    let delta = 0;
    let bias = 72;
    const digit = (d) => String.fromCharCode(d < 26 ? d + 97 : d + 22);
    const adapt = (d, count, first) => {
      d = first ? Math.floor(d / 700) : d >> 1;
      d += Math.floor(d / count);
      let k = 0;
      while (d > 455) {
        d = Math.floor(d / 35);
        k += 36;
      }
      return k + Math.floor((36 * d) / (d + 38));
    };
    while (handled < cps.length) {
      const m = Math.min(...cps.filter((c) => c >= n));
      delta += (m - n) * (handled + 1);
      n = m;
      for (const c of cps) {
        if (c < n) delta++;
        if (c === n) {
          let q = delta;
          for (let k = 36; ; k += 36) {
            const t = k <= bias ? 1 : k >= bias + 26 ? 26 : k - bias;
            if (q < t) break;
            out += digit(t + ((q - t) % (36 - t)));
            q = Math.floor((q - t) / (36 - t));
          }
          out += digit(q);
          bias = adapt(delta, handled + 1, handled === basic);
          delta = 0;
          handled++;
        }
      }
      delta++;
      n++;
    }
    return out;
  }
  function normalizeHost(raw) {
    let host = String(raw || "").trim();
    if (host.includes(":") && !host.startsWith("[")) host = `[${host}]`;
    if (host.startsWith("[")) return host.toLowerCase();
    host = host.replace(/\.+$/, "");
    return host
      .split(".")
      .map((label) => {
        const l = label.normalize("NFC").toLowerCase();
        return /[^\x00-\x7f]/.test(l) ? "xn--" + punycode(l) : l;
      })
      .join(".");
  }

  function parsePattern(raw, title) {
    if (typeof raw !== "string" || !raw.trim()) throw new Error(`${title}: expected domain patterns as non-empty strings, got ${JSON.stringify(raw)}`);
    let p = raw.trim().toLowerCase();
    let scheme = null;
    const m = /^([a-z*][a-z0-9+.*-]*):\/\/(.*)$/.exec(p);
    if (m) {
      scheme = m[1];
      p = m[2];
    }
    p = p.replace(/\/.*$/, "");
    let port = null;
    const pm = /^(.*):(\d+|\*)$/.exec(p);
    if (pm && !p.startsWith("[")) {
      p = pm[1];
      port = pm[2] === "*" ? null : pm[2];
    }
    const host = p;
    if (host !== "*") {
      if ((host.match(/\*/g) || []).length > 1) throw new Error(`${title}: ${JSON.stringify(raw)}: only one wildcard is allowed`);
      if (host.endsWith(".*")) throw new Error(`${title}: ${JSON.stringify(raw)}: wildcard top-level domains are not allowed`);
      if (host.includes("*") && !host.startsWith("*.")) throw new Error(`${title}: ${JSON.stringify(raw)}: use *.example.com; other wildcards are not allowed`);
      if (!host || /[\s/]/.test(host)) throw new Error(`${title}: ${JSON.stringify(raw)}: expected a domain`);
    }
    const normalized = host === "*" ? host : host.startsWith("*.") ? "*." + normalizeHost(host.slice(2)) : normalizeHost(host);
    if (!normalized || normalized === "*.") throw new Error(`${title}: ${JSON.stringify(raw)}: expected a domain`);
    return { raw, scheme, host: normalized, port };
  }

  const globRe = (glob) => new RegExp("^" + glob.replace(/[.+^${}()|[\]\\?]/g, "\\$&").replace(/\*/g, ".*") + "$");
  const LOOPBACK = /^(localhost|127(?:\.\d{1,3}){3}|\[::1\])$/;

  // `secure`: a pattern without a scheme matches https only (and http on a
  // loopback host); otherwise it matches http and https.
  function urlMatches(url, pattern, secure) {
    let u;
    try {
      u = new core.URL(url);
    } catch {
      return false;
    }
    const scheme = String(u.protocol || "").replace(/:$/, "").toLowerCase();
    const host = normalizeHost(u.hostname || "");
    if (!host) return false;
    if (pattern.scheme) {
      if (!globRe(pattern.scheme).test(scheme)) return false;
    } else if (secure) {
      if (!(scheme === "https" || (scheme === "http" && LOOPBACK.test(host)))) return false;
    } else if (scheme !== "http" && scheme !== "https") return false;
    if (pattern.port !== null) {
      const port = u.port || (scheme === "https" ? "443" : scheme === "http" ? "80" : "");
      if (port !== pattern.port) return false;
    }
    const h = pattern.host;
    if (h === "*") return true;
    if (h.startsWith("*.")) {
      const base = h.slice(2);
      return host === base || host.endsWith("." + base);
    }
    if (host === h) return true;
    // A root domain also covers www (the watchdog's www variant).
    return h.split(".").length === 2 && host === "www." + h;
  }

  // ---------------------------------------------------------------------------
  // Animated PNG from same-size PNG frames, by moving their IDAT data into
  // APNG frame chunks (no decoding).

  const CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })();
  function crc32(bytes) {
    let c = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  }
  function pngChunks(png) {
    const dv = new DataView(png.buffer, png.byteOffset, png.byteLength);
    const out = [];
    for (let off = 8; off + 8 <= png.length;) {
      const len = dv.getUint32(off);
      const type = String.fromCharCode(png[off + 4], png[off + 5], png[off + 6], png[off + 7]);
      out.push({ type, data: png.subarray(off + 8, off + 8 + len) });
      off += 12 + len;
    }
    return out;
  }
  function chunk(type, data) {
    const out = new Uint8Array(12 + data.length);
    const dv = new DataView(out.buffer);
    dv.setUint32(0, data.length);
    for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
    out.set(data, 8);
    dv.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
    return out;
  }
  function u32s(...values) {
    const b = new Uint8Array(values.length * 4);
    const dv = new DataView(b.buffer);
    values.forEach((v, i) => dv.setUint32(i * 4, v));
    return b;
  }
  // Frames whose header differs from the first (another size) are skipped.
  function buildApng(frames, delayMs = 800) {
    const parsed = frames.map((f) => pngChunks(f instanceof Uint8Array ? f : new Uint8Array(f)));
    const ihdr = parsed[0].find((c) => c.type === "IHDR").data;
    const same = parsed.filter((cs) => {
      const h = cs.find((c) => c.type === "IHDR");
      return h && h.data.length === ihdr.length && h.data.every((b, i) => b === ihdr[i]);
    });
    const width = new DataView(ihdr.buffer, ihdr.byteOffset).getUint32(0);
    const height = new DataView(ihdr.buffer, ihdr.byteOffset).getUint32(4);
    const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("acTL", u32s(same.length, 0))];
    let seq = 0;
    same.forEach((cs, i) => {
      const fctl = new Uint8Array(26);
      fctl.set(u32s(seq++, width, height, 0, 0));
      new DataView(fctl.buffer).setUint16(20, delayMs);
      new DataView(fctl.buffer).setUint16(22, 1000);
      parts.push(chunk("fcTL", fctl));
      for (const c of cs) {
        if (c.type !== "IDAT") continue;
        if (i === 0) parts.push(chunk("IDAT", c.data));
        else {
          const d = new Uint8Array(4 + c.data.length);
          d.set(u32s(seq++));
          d.set(c.data, 4);
          parts.push(chunk("fdAT", d));
        }
      }
    });
    parts.push(chunk("IEND", new Uint8Array(0)));
    return { bytes: Buffer.concat(parts.map((p) => Buffer.from(p))), frames: same.length, skipped: frames.length - same.length };
  }

  // ---------------------------------------------------------------------------
  // Page functions (agent world: closed shadow roots are open to it).

  // The frame as Markdown blocks. Iframes become placeholders "\u0000F<i>\u0000"
  // with their handles, so the host stitches each frame's Markdown in place.
  function markdownOfFrame(opts) {
    const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
    const frames = [];
    const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "META", "LINK", "TITLE", "SVG", "CANVAS", "VIDEO", "AUDIO", "OBJECT", "EMBED", "MAP", "DIALOG"]);
    const OUTSIDE_MAIN = new Set(["navigation", "banner", "contentinfo", "complementary", "search"]);
    const styles = new Map();
    const style = (el) => {
      let cs = styles.get(el);
      if (!cs) styles.set(el, (cs = getComputedStyle(el)));
      return cs;
    };
    const tag = (el) => (el.tagName || "").toUpperCase();
    const landmark = (el) => {
      const role = el.getAttribute("role");
      if (role) return role;
      const t = tag(el);
      if (t === "NAV") return "navigation";
      if (t === "ASIDE") return "complementary";
      if ((t === "HEADER" || t === "FOOTER") && !el.closest("article, main, section, [role=main], [role=article]")) return t === "HEADER" ? "banner" : "contentinfo";
      return null;
    };
    const skipped = (el, ctx) => {
      if (SKIP.has(tag(el))) return true;
      if (tag(el) === "DIALOG" && el.open) return false;
      const cs = style(el);
      if (cs.display === "none" || cs.contentVisibility === "hidden") return true;
      if (ctx.main && OUTSIDE_MAIN.has(landmark(el))) return true;
      return false;
    };
    // Children in the flat tree: a shadow root's, a slot's assigned nodes,
    // and the children of display:contents boxes in their place.
    const kids = (el) => {
      const out = [];
      for (const c of ownKids(el)) {
        if (c.nodeType === 1 && !SKIP.has(tag(c)) && style(c).display === "contents") out.push(...kids(c));
        else out.push(c);
      }
      return out;
    };
    const ownKids = (el) => {
      if (el.shadowRoot) return [...el.shadowRoot.childNodes];
      if (tag(el) === "SLOT") {
        const assigned = el.assignedNodes({ flatten: true });
        return assigned.length ? assigned : [...el.childNodes];
      }
      if (tag(el) === "DETAILS" && !el.open) return [...el.children].filter((c) => tag(c) === "SUMMARY");
      return [...el.childNodes];
    };
    const sub = (el, ctx) => {
      const cs = style(el);
      return cs.visibility === "hidden" || cs.visibility === "collapse" ? { ...ctx, hidden: true } : cs.visibility === "visible" ? { ...ctx, hidden: false } : ctx;
    };
    const isInline = (el) => {
      const t = tag(el);
      if (/^(H[1-6]|P|PRE|UL|OL|TABLE|BLOCKQUOTE|HR|IFRAME|FRAME|LI|DL|DT|DD|FIGURE|SECTION|ARTICLE|DETAILS|SUMMARY)$/.test(t)) return false;
      return style(el).display.startsWith("inline");
    };
    const collapse = (s) => s.replace(/[\s ]+/g, " ");
    const esc = (s) => s.replace(/([\\`*_[\]])/g, "\\$1");
    const absURL = (v) => {
      try {
        return new URL(v, document.baseURI).href;
      } catch (e) {
        return v;
      }
    };
    const fieldValue = (el) => {
      const t = tag(el);
      if (t === "SELECT") return [...el.selectedOptions].map((o) => o.label || o.text).join(", ");
      if (t === "TEXTAREA") return el.value;
      if (t === "INPUT") {
        const type = (el.type || "text").toLowerCase();
        if (type === "password" || type === "hidden" || type === "file") return "";
        if (type === "checkbox" || type === "radio") return el.checked ? "[x]" : "[ ]";
        if (type === "submit" || type === "button" || type === "reset") return el.value;
        return el.value;
      }
      return "";
    };

    function inline(node, ctx) {
      if (node.nodeType === 3) return ctx.hidden ? "" : collapse(node.data);
      if (node.nodeType !== 1 || skipped(node, ctx)) return "";
      ctx = sub(node, ctx);
      const t = tag(node);
      if (t === "BR") return "\n";
      if (t === "IFRAME" || t === "FRAME") return "";
      if (t === "IMG") {
        if (ctx.hidden) return "";
        const alt = collapse(node.getAttribute("alt") || "").trim();
        if (opts.images && node.getAttribute("src")) return `![${esc(alt)}](${absURL(node.getAttribute("src"))})`;
        return "";
      }
      if (t === "INPUT" || t === "TEXTAREA" || t === "SELECT") {
        if (ctx.hidden) return "";
        const v = fieldValue(node);
        if (!v) return "";
        return v === "[x]" || v === "[ ]" ? v + " " : t === "INPUT" && /^(submit|button|reset)$/i.test(node.type) ? v : "`" + collapse(v) + "`";
      }
      const inner = kids(node).map((c) => inline(c, ctx)).join("");
      const trimmed = inner.trim();
      if (!trimmed && t === "A" && opts.links && node.getAttribute("href") && !ctx.hidden) {
        // An icon link is named by its label, its SVG title or its image's alt.
        const svgTitle = node.querySelector("svg title");
        const img = node.querySelector("img[alt]");
        const label = collapse(node.getAttribute("aria-label") || (svgTitle && svgTitle.textContent) || (img && img.getAttribute("alt")) || node.getAttribute("title") || "").trim();
        if (label && !/^(javascript:|#$)/i.test(node.getAttribute("href").trim())) return `[${esc(label)}](${absURL(node.getAttribute("href"))})`;
      }
      if (!trimmed) return inner && /\s/.test(inner) ? " " : "";
      const pad = (s) => (/^\s/.test(inner) ? " " : "") + s + (/\s$/.test(inner) ? " " : "");
      if (t === "A") {
        const href = node.getAttribute("href");
        if (opts.links && href && !/^(javascript:|#$)/i.test(href.trim())) return pad(`[${trimmed.replace(/\n+/g, " ")}](${absURL(href)})`);
        return inner;
      }
      if (t === "STRONG" || t === "B") return pad(`**${trimmed}**`);
      if (t === "EM" || t === "I") return pad(`*${trimmed}*`);
      if (t === "CODE" || t === "KBD" || t === "SAMP") return pad("`" + trimmed + "`");
      if (t === "S" || t === "DEL") return pad(`~~${trimmed}~~`);
      return inner;
    }
    const tidy = (s) => s.split("\n").map((l) => l.replace(/ +/g, " ").trim()).filter(Boolean).join("\n");

    // Blocks of a container: inline runs between block children become paragraphs.
    function blocks(node, ctx) {
      const out = [];
      let run = "";
      const end = () => {
        const t = tidy(run);
        if (t) out.push(t);
        run = "";
      };
      for (const c of kids(node)) {
        if (c.nodeType === 3) {
          run += ctx.hidden ? "" : collapse(c.data);
          continue;
        }
        if (c.nodeType !== 1 || skipped(c, ctx)) continue;
        if (isInline(c) && !(tag(c) === "IFRAME" || tag(c) === "FRAME")) {
          run += inline(c, ctx);
          continue;
        }
        end();
        out.push(...block(c, sub(c, ctx)));
      }
      end();
      return out;
    }
    function list(el, ctx) {
      const ordered = tag(el) === "OL";
      let n = Number(el.getAttribute("start")) || 1;
      const lines = [];
      for (const li of kids(el)) {
        if (li.nodeType !== 1 || skipped(li, ctx)) continue;
        const parts = tag(li) === "LI" ? blocks(li, sub(li, ctx)) : block(li, sub(li, ctx));
        if (!parts.length) continue;
        const marker = ordered ? `${n++}. ` : "- ";
        const text = parts.join("\n").split("\n");
        lines.push(marker + text[0], ...text.slice(1).map((l) => " ".repeat(marker.length) + l));
      }
      return lines.length ? [lines.join("\n")] : [];
    }
    function table(el, ctx) {
      const rows = [...el.rows].filter((r) => !skipped(r, ctx));
      const layout = !rows.length || el.querySelector("table") || el.getAttribute("role") === "presentation" || rows.every((r) => r.cells.length <= 1);
      if (layout) return blocks(el, ctx);
      const width = Math.max(...rows.map((r) => r.cells.length));
      const cell = (c) => tidy(inline(c, sub(c, ctx))).replace(/\n/g, " ").replace(/\|/g, "\\|");
      const line = (r) => "| " + [...r.cells].map(cell).concat(Array(width - r.cells.length).fill("")).join(" | ") + " |";
      const caption = el.caption ? tidy(inline(el.caption, ctx)) : "";
      const lines = [line(rows[0]), "|" + " --- |".repeat(width), ...rows.slice(1).map(line)];
      return caption ? [caption, lines.join("\n")] : [lines.join("\n")];
    }
    function block(el, ctx) {
      const t = tag(el);
      const h = /^H([1-6])$/.exec(t);
      if (h) {
        const text = tidy(inline(el, ctx)).replace(/\n/g, " ");
        return text ? ["#".repeat(Number(h[1])) + " " + text] : [];
      }
      if (t === "PRE") return ctx.hidden ? [] : ["```\n" + el.textContent.replace(/\n$/, "") + "\n```"];
      if (t === "UL" || t === "OL") return list(el, ctx);
      if (t === "TABLE") return table(el, ctx);
      if (t === "HR") return ["---"];
      if (t === "BLOCKQUOTE") {
        const inner = blocks(el, ctx);
        return inner.length ? [inner.join("\n\n").split("\n").map((l) => "> " + l).join("\n")] : [];
      }
      if (t === "IFRAME" || t === "FRAME") {
        if (ctx.hidden) return [];
        frames.push(A.handleFor(el));
        return [`\u0000F${frames.length - 1}\u0000`];
      }
      if (t === "INPUT" || t === "TEXTAREA" || t === "SELECT" || t === "IMG") {
        const s = tidy(inline(el, ctx));
        return s ? [s] : [];
      }
      return blocks(el, ctx);
    }

    let rootEl = document.body || document.documentElement;
    let main = false;
    if (opts.main) {
      const visible = (e) => e && style(e).display !== "none" && (e.innerText || "").trim().length > 0;
      const mainEl = [...document.querySelectorAll("main, [role=main]")].find(visible);
      const articles = [...document.querySelectorAll("article, [role=article]")].filter(visible);
      if (mainEl) rootEl = mainEl;
      else if (articles.length === 1) rootEl = articles[0];
      else main = true;
    }
    const out = rootEl ? blocks(rootEl, { hidden: false, main }) : [];
    return { blocks: out, frames };
  }

  // Structured data by selectors (Playwright syntax: CSS, text=, role=, ...;
  // they reach into shadow roots). A spec is "selector" (text), "selector@attr"
  // (attribute; href and src resolve to absolute URLs), "@attr" or "." (the
  // scope itself), ["spec"] (every match), or an object: { $: "selector", ...fields }
  // is one object per match, an object without $ is one nested object.
  function extractInFrame(schema, opts) {
    const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
    const limit = opts.limit || 1000;
    const all = (sel, scope) => A.queryAll(sel, scope && scope !== document ? A.handleFor(scope) : undefined).map((h) => A.element(h));
    const text = (el) => {
      const t = (el.tagName || "").toUpperCase();
      if (t === "INPUT" || t === "TEXTAREA") return el.value;
      if (t === "SELECT") return [...el.selectedOptions].map((o) => o.label || o.text).join(", ");
      return (el.innerText !== undefined ? el.innerText : el.textContent || "").replace(/[\s ]+/g, " ").trim();
    };
    const split = (spec) => {
      const m = /^(.*?)@([A-Za-z_][\w:.-]*)$/.exec(spec);
      if (m && !/["'\]]/.test(spec.slice(m[1].length))) return [m[1].trim(), m[2]];
      return [spec.trim(), null];
    };
    const read = (el, attr) => {
      if (!el) return null;
      if (!attr) return text(el);
      if ((attr === "href" || attr === "src") && typeof el[attr] === "string" && el[attr]) return el[attr];
      return el.getAttribute(attr);
    };
    const leaf = (spec, scope, many) => {
      const [sel, attr] = split(spec);
      if (!sel || sel === ".") return many ? [read(scope, attr)] : read(scope, attr);
      const els = all(sel, scope);
      return many ? els.slice(0, limit).map((e) => read(e, attr)) : read(els[0], attr);
    };
    const run = (spec, scope) => {
      if (typeof spec === "string") return leaf(spec, scope, false);
      if (Array.isArray(spec)) {
        if (spec.length !== 1) throw new Error("page.extract: a list spec has one item: [\"selector\"] or [{ $: \"selector\", ... }]");
        const item = spec[0];
        if (typeof item === "string") return leaf(item, scope, true);
        if (item && typeof item === "object" && Array.isArray(item.__cmuxPairs) && item.__cmuxPairs.some(([k, v]) => k === "$" && typeof v === "string")) return run(item, scope);
        throw new Error("page.extract: a list spec has one item: [\"selector\"] or [{ $: \"selector\", ... }]");
      }
      // Objects travel as key/value pairs both ways, so their key order
      // survives drivers whose JSON does not keep it (the app's).
      if (spec && typeof spec === "object" && Array.isArray(spec.__cmuxPairs)) {
        const entries = spec.__cmuxPairs;
        const each = entries.find(([k]) => k === "$");
        const fields = (s) => ({ __cmuxPairs: entries.filter(([k]) => k !== "$").map(([k, v]) => [k, run(v, s)]) });
        if (each && typeof each[1] === "string") return all(each[1], scope).slice(0, limit).map(fields);
        return fields(scope);
      }
      throw new Error(`page.extract: expected a selector string, [spec] or an object, got ${JSON.stringify(spec)}`);
    };
    const scope = opts.scope ? A.element(opts.scope) : document;
    return run(schema, scope);
  }

  // Text matches with context, like grep over what the page renders.
  function searchTextInFrame(opts) {
    const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
    const scope = opts.scope ? A.element(opts.scope) : document.body || document.documentElement;
    const visible = (el) => {
      if (!el) return false;
      if (typeof el.checkVisibility === "function") return el.checkVisibility({ visibilityProperty: true, contentVisibilityAuto: true });
      const cs = getComputedStyle(el);
      return cs.display !== "none" && cs.visibility !== "hidden";
    };
    const blockOf = (el) => {
      for (let e = el; e; e = e.parentElement || (e.getRootNode && e.getRootNode().host)) {
        if (!getComputedStyle(e).display.startsWith("inline")) return e;
      }
      return null;
    };
    const nodes = [];
    const walk = (root) => {
      for (const n of root.childNodes) {
        if (n.nodeType === 3) {
          if (n.data.trim() && visible(n.parentElement)) nodes.push(n);
        } else if (n.nodeType === 1) {
          const t = n.tagName.toUpperCase();
          if (t === "SCRIPT" || t === "STYLE" || t === "NOSCRIPT" || t === "TEMPLATE") continue;
          if (n.shadowRoot) walk(n.shadowRoot);
          else walk(n);
        }
      }
    };
    walk(scope);
    let text = "";
    const starts = [];
    let lastBlock = null;
    for (const n of nodes) {
      const b = blockOf(n.parentElement);
      if (text && b !== lastBlock) text += "\n";
      lastBlock = b;
      starts.push(text.length);
      text += n.data.replace(/[\s ]+/g, " ");
    }
    let re;
    try {
      re = opts.regex ? new RegExp(opts.pattern, opts.caseSensitive ? "g" : "gi") : new RegExp(opts.pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), opts.caseSensitive ? "g" : "gi");
    } catch (e) {
      throw new Error(`page.searchText: invalid pattern: ${e.message}`);
    }
    const matches = [];
    let total = 0;
    let m;
    while ((m = re.exec(text))) {
      if (!m[0].length) {
        re.lastIndex++;
        continue;
      }
      total++;
      if (matches.length >= opts.limit) continue;
      let lo = 0;
      let hi = starts.length - 1;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (starts[mid] <= m.index) lo = mid;
        else hi = mid - 1;
      }
      const a = Math.max(0, m.index - opts.context);
      const b = Math.min(text.length, m.index + m[0].length + opts.context);
      const el = nodes[lo] && nodes[lo].parentElement;
      matches.push({ match: m[0], context: (a > 0 ? "…" : "") + text.slice(a, b).replace(/\n/g, " ").trim() + (b < text.length ? "…" : ""), handle: el ? A.handleFor(el) : null });
    }
    return { total, matches };
  }

  function dropdownInFrame(handle) {
    const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
    const el = A.element(handle);
    const clean = (s) => (s || "").replace(/[\s ]+/g, " ").trim();
    if (el.tagName && el.tagName.toUpperCase() === "SELECT") {
      return { kind: "select", multiple: el.multiple, options: [...el.options].map((o, index) => ({ index, label: o.label || clean(o.text), value: o.value, selected: o.selected, disabled: o.disabled })) };
    }
    const rootNode = el.getRootNode();
    const byId = (id) => (rootNode.getElementById ? rootNode.getElementById(id) : document.getElementById(id));
    const role = el.getAttribute("role");
    let popup = null;
    if (role === "listbox" || role === "menu" || role === "tree" || role === "radiogroup") popup = el;
    else {
      for (const attr of ["aria-controls", "aria-owns"]) {
        for (const id of (el.getAttribute(attr) || "").split(/\s+/).filter(Boolean)) popup = popup || byId(id);
      }
      if (!popup) popup = el.querySelector("[role=listbox], [role=menu], [role=tree]");
    }
    if (!popup) return { kind: "none", options: [] };
    const items = [...popup.querySelectorAll("[role=option], [role=menuitem], [role=menuitemradio], [role=menuitemcheckbox], [role=treeitem], [role=radio]")]
      .filter((o) => !(typeof o.checkVisibility === "function") || o.checkVisibility({ visibilityProperty: true }));
    return {
      kind: "aria",
      multiple: popup.getAttribute("aria-multiselectable") === "true",
      options: items.map((o, index) => ({
        index,
        label: clean(o.getAttribute("aria-label") || o.innerText || o.textContent),
        value: o.getAttribute("data-value") || o.getAttribute("value") || null,
        selected: o.getAttribute("aria-selected") === "true" || o.getAttribute("aria-checked") === "true",
        disabled: o.getAttribute("aria-disabled") === "true",
        handle: A.handleFor(o),
      })),
    };
  }

  function scrollInfoInFrame(handle) {
    const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
    const el = handle ? A.element(handle) : null;
    const doc = document.scrollingElement || document.documentElement;
    const target = el || doc;
    const vh = el ? el.clientHeight : innerHeight;
    const y = el ? el.scrollTop : scrollY;
    const r1 = (n) => Math.round(n * 10) / 10;
    return {
      x: Math.round(el ? el.scrollLeft : scrollX),
      y: Math.round(y),
      viewportHeight: vh,
      scrollHeight: target.scrollHeight,
      pagesAbove: vh ? r1(y / vh) : 0,
      pagesBelow: vh ? r1(Math.max(0, target.scrollHeight - y - vh) / vh) : 0,
    };
  }

  // Search engine results pages, parsed in a blank tab's DOM parser.
  function parseResults(arg) {
    const doc = new DOMParser().parseFromString(arg.html, "text/html");
    const clean = (s) => (s || "").replace(/[\s ]+/g, " ").trim();
    const abs = (href) => {
      try {
        return new URL(href, arg.base).href;
      } catch (e) {
        return null;
      }
    };
    const out = [];
    const seen = new Set();
    const add = (title, url, snippet) => {
      if (!title || !url || !/^https?:/.test(url) || seen.has(url) || out.length >= arg.limit) return;
      seen.add(url);
      out.push({ title, url, snippet: snippet || "" });
    };
    if (arg.engine === "duckduckgo") {
      for (const r of doc.querySelectorAll(".result, .web-result")) {
        if (r.classList.contains("result--ad")) continue;
        const a = r.querySelector("a.result__a");
        if (!a) continue;
        let url = abs(a.getAttribute("href"));
        try {
          const u = new URL(url);
          if (/duckduckgo\.com$/.test(u.hostname) && u.pathname === "/l/" && u.searchParams.get("uddg")) url = u.searchParams.get("uddg");
        } catch (e) {}
        add(clean(a.textContent), url, clean((r.querySelector(".result__snippet") || {}).textContent));
      }
      return { results: out, blocked: !out.length && !!doc.querySelector(".anomaly-modal, #challenge-form, .challenge-form") };
    }
    for (const r of doc.querySelectorAll("#b_results > li.b_algo, li.b_algo")) {
      const a = r.querySelector("h2 a");
      if (!a) continue;
      let url = abs(a.getAttribute("href"));
      try {
        const u = new URL(url);
        const enc = u.pathname === "/ck/a" && u.searchParams.get("u");
        if (enc && enc.startsWith("a1")) url = atob(enc.slice(2).replace(/-/g, "+").replace(/_/g, "/"));
      } catch (e) {}
      add(clean(a.textContent), url, clean((r.querySelector(".b_caption p, .b_lineclamp2, .b_lineclamp3, .b_algoSlug") || {}).textContent));
    }
    return { results: out, blocked: !out.length && !!doc.querySelector("#b_captcha, .captcha") };
  }

  const ENGINES = {
    duckduckgo: "https://html.duckduckgo.com/html/?q=%s",
    bing: "https://www.bing.com/search?q=%s",
  };

  // ---------------------------------------------------------------------------

  const fnSource = (fn) => fn.toString();
  const agentCall = (frame, fn, ...args) => frame._call("agent", fnSource(fn), args);
  const errCode = (e) => e && (e.code || (e.cause && e.cause.code));

  function install(ctx) {
    const { session, host, globals, sessionApi, fetch, fs, path, currentPage, show } = ctx;
    const print = (level, text) => {
      try {
        host.print(level, text);
      } catch {}
    };

    // ---- secrets -------------------------------------------------------------
    // Values live in the host (browser-host.md section 4), never in this
    // context: main's natives host.secrets(op, args) and host.policy(op,
    // args) answer with names, never values. A secret set here is
    // agent-known (the agent has the value anyway) and only masked.
    // cmux-next: secret(name) is a {__secret: name} handle that the host
    // resolves after checking the receiving frame's origin (TOTP included);
    // locator.fill and type send the handle, not main's {secret: name}.
    const secretsHost = (op, args) => host.secrets(op, args || {});
    const isSecret = (v) => v !== null && typeof v === "object" && !Array.isArray(v) && typeof v.__secret === "string" && Object.keys(v).length === 1;
    function makeHandle(name) {
      const h = { __secret: name };
      Object.defineProperty(h, "toString", { value: () => `<secret:${name}>`, enumerable: false });
      Object.defineProperty(h, Symbol.for("nodejs.util.inspect.custom"), { value: () => `<secret:${name}>`, enumerable: false });
      return Object.freeze(h);
    }
    function checkSecretArgs(name, value, options, title) {
      if (typeof name !== "string" || !/^[\w.-]{1,64}$/.test(name)) throw new Error(`${title}: name: expected letters, digits, _, . or - (at most 64), got ${JSON.stringify(name)}`);
      if (typeof value !== "string" || !value) throw new Error(`${title}: ${name}: value: expected a non-empty string`);
      const domains = options && options.domains;
      if (!Array.isArray(domains) || !domains.length) throw new Error(`${title}: ${name}: domains: expected the domains it may be typed into, such as ["example.com"]; a secret without domains is not accepted`);
      for (const d of domains) parsePattern(d, title);
      return { domains: [...domains], totp: !!(options.totp || /bu_2fa_code$/.test(name)) };
    }
    const secrets = Object.freeze({
      // set(name, value, { domains, totp }): the value is typed only into
      // frames on those domains and is masked as <secret:name> everywhere.
      set(name, value, options) {
        const opts = checkSecretArgs(name, value, options, "secrets.set");
        return secretsHost("set", { name, value, domains: opts.domains, totp: opts.totp });
      },
      // { "<domain pattern>": { name: value } }, as an object or a JSON file
      // path (read by the host, so the values never enter this context). A
      // value { value, totp } is accepted.
      load(source) {
        if (typeof source === "string") return secretsHost("load", { path: source });
        if (!source || typeof source !== "object" || Array.isArray(source)) throw new Error("secrets.load: expected { \"<domain pattern>\": { name: value } }");
        for (const [pattern, entries] of Object.entries(source)) {
          if (!entries || typeof entries !== "object") throw new Error(`secrets.load: ${JSON.stringify(pattern)}: a secret needs domains; expected { "<domain pattern>": { name: value } }`);
          for (const [name, v] of Object.entries(entries)) checkSecretArgs(name, v && typeof v === "object" ? v.value : v, { domains: [pattern] }, "secrets.load");
        }
        return secretsHost("load", { object: source });
      },
      list: () => secretsHost("list"),
      has: (name) => secretsHost("has", { name }),
      delete: (name) => secretsHost("delete", { name }),
      clear: () => {
        secretsHost("clear");
      },
    });
    function secret(name) {
      if (!secrets.has(name)) throw new Error(`secret(${JSON.stringify(name)}): no such secret; register it with secrets.set(name, value, { domains }) or secrets.load(file)`);
      return makeHandle(name);
    }

    // ---- domain policy -------------------------------------------------------
    // Enforced by the host below this context. Agent code may narrow the
    // policy for its session (cmux-next: the host intersects it with the
    // user's policy and refuses a change after a lock); it never widens it.
    const policyHost = (op, args) => host.policy(op, args || {});
    function setPolicy(field, title, list, options) {
      if (list === undefined) return policyHost("get")[field];
      if (list !== null && !Array.isArray(list)) throw new Error(`${title}: expected an array of domain patterns or null, got ${JSON.stringify(list)}`);
      if (list) for (const d of list) parsePattern(d, title);
      return policyHost("set", { [field]: list, lock: !!(options && options.lock), title })[field];
    }

    // ---- browser-context options (session.configure) -------------------------------
    const contextConfig = {};
    async function configure(options) {
      if (options === null || typeof options !== "object" || Array.isArray(options)) throw new Error(`session.configure: options: expected an object, got ${JSON.stringify(options)}`);
      const known = ["userAgent", "extraHTTPHeaders", "permissions", "proxy"];
      const unknown = Object.keys(options).filter((k) => !known.includes(k));
      if (unknown.length) throw new Error(`session.configure: unknown option ${unknown.map((k) => JSON.stringify(k)).join(", ")}; expected ${known.join(", ")}`);
      const params = {};
      if ("userAgent" in options) {
        if (options.userAgent !== null && typeof options.userAgent !== "string") throw new Error("session.configure: userAgent: expected a string or null");
        params.userAgent = options.userAgent;
      }
      if ("extraHTTPHeaders" in options) {
        const h = options.extraHTTPHeaders;
        if (h !== null && (typeof h !== "object" || Array.isArray(h) || Object.values(h).some((v) => typeof v !== "string"))) throw new Error("session.configure: extraHTTPHeaders: expected { name: string value } or null");
        params.extraHTTPHeaders = h || {};
      }
      if ("permissions" in options) {
        const list = options.permissions;
        if (list !== null && (!Array.isArray(list) || list.some((v) => typeof v !== "string"))) throw new Error("session.configure: permissions: expected an array of permission names or null");
        params.permissions = list || [];
      }
      if ("proxy" in options) {
        const px = options.proxy;
        if (px !== null && (typeof px !== "object" || typeof px.server !== "string" || !px.server)) throw new Error("session.configure: proxy: expected { server, username?, password?, bypass? } or null");
        params.proxy = px;
      }
      const result = await session.driver.call("session.configure", params);
      for (const [k, v] of Object.entries(params)) {
        if (v === null || (Array.isArray(v) && !v.length) || (k === "extraHTTPHeaders" && !Object.keys(v).length)) delete contextConfig[k];
        else contextConfig[k] = k === "proxy" ? Object.fromEntries(["server", "username", "bypass"].filter((f) => v[f] !== undefined).map((f) => [f, v[f]])) : v;
      }
      const out = { ...contextConfig };
      if (result && result.proxy) out.proxyAppliesTo = "tabs opened from now on";
      return out;
    }

    // ---- downloads -------------------------------------------------------------
    const downloads = [];
    const downloadsById = new Map();

    // ---- recording -------------------------------------------------------------
    let recorder = null;
    let recordCount = 0;
    const RECORDED = new Set(["tab.navigate", "tab.history", "tab.reload", "tabs.open", "tabs.close", "input.mouse", "input.key", "input.insertText", "input.drag", "input.setFiles", "dialog.respond", "filechooser.respond"]);
    const NAVIGATIONS = new Set(["tab.navigate", "tab.history", "tab.reload"]);
    // A secret handle is recorded by name; other text as given (the host
    // masks agent-known secret values in every file it writes).
    const traceText = (t) => (isSecret(t) ? `<secret:${t.__secret}>` : t);
    function traceParams(method, p) {
      const o = {};
      if (p.url !== undefined) o.url = p.url;
      if (method === "input.mouse") Object.assign(o, { type: p.type, x: p.x, y: p.y, button: p.button, deltaX: p.deltaX, deltaY: p.deltaY });
      if (method === "input.key") Object.assign(o, { type: p.type, modifiers: p.modifiers, key: traceText(p.key) });
      if (method === "input.insertText") o.text = traceText(p.text);
      if (method === "input.setFiles") o.files = (p.files || []).map((f) => f.name);
      if (method === "tab.history") o.delta = p.delta;
      if (method === "dialog.respond") o.accept = p.accept;
      return o;
    }
    async function recordFrame(page) {
      if (!recorder || !recorder.screenshots || page._closed || recorder.busy) return;
      recorder.busy = true;
      try {
        const r = await session.call("tab.screenshot", { targetId: page._targetId, format: "png" });
        const file = path.join(recorder.dir, `frame-${String(++recorder.frames).padStart(4, "0")}.png`);
        fs.writeFileSync(file, Buffer.from(r.base64, "base64"));
        recorder.frameFiles.push(file);
        return file;
      } catch {
        return null;
      } finally {
        recorder.busy = false;
      }
    }
    function trace(entry) {
      if (!recorder) return;
      recorder.actions++;
      fs.appendFileSync(recorder.trace, JSON.stringify(entry) + "\n");
    }

    // ---- hooks -------------------------------------------------------------------
    // Recording and downloads only: the policy, secret resolution, masking
    // and capture masking happen in the host around each driver call.
    const hooks = {
      isSecret,
      async beforeCall() {},
      afterCall(method, params, promise) {
        if (!recorder) return promise;
        return promise.then(async (r) => {
          if (RECORDED.has(method) && !(method === "input.mouse" && params.type === "move") && !(method === "input.key" && params.type === "up")) {
            const entry = { t: new Date(session.now()).toISOString(), tab: params.targetId, method, ...traceParams(method, params) };
            if (NAVIGATIONS.has(method) || method === "tabs.open") {
              const page = session.pages.get(params.targetId || (r && r.targetId));
              if (page) entry.frame = await recordFrame(page);
            }
            trace(entry);
          }
          return r;
        });
      },
      onEvent(event, payload) {
        return payload;
      },
      afterEvent(event, p) {
        if (event === "download.started") {
          const d = { id: p.downloadId, url: p.url, suggestedFilename: p.suggestedFilename, tab: p.targetId, state: "started", path: null, error: null, startedAt: new Date(session.now()).toISOString() };
          downloads.push(d);
          downloadsById.set(p.downloadId, d);
          trace({ t: d.startedAt, tab: p.targetId, event: "download", url: p.url, suggestedFilename: p.suggestedFilename });
        } else if (event === "download.finished") {
          const d = downloadsById.get(p.downloadId);
          if (d) Object.assign(d, { state: p.error ? "failed" : "finished", path: p.path || null, error: p.error || null });
        }
      },
      async afterAction(page) {
        if (recorder) {
          const file = await recordFrame(page);
          if (file) trace({ t: new Date(session.now()).toISOString(), tab: page._targetId, event: "after-action", url: page.url(), frame: file });
        }
      },
    };
    // Agent code can reach the session object; the hooks stay fixed. They
    // are conveniences: the guards are native and do not depend on them.
    Object.freeze(hooks);
    Object.defineProperty(session, "agentTools", { value: hooks, writable: false, configurable: false, enumerable: false });

    // ---- storage state -------------------------------------------------------------
    // Default scope: the sites (registrable domains) of one tab, so a saved
    // state never carries the rest of the user's profile by accident.
    // { all: true } saves everything; { urls } saves what those URLs see.
    // The host answers a host's site (cmux-next: from a compact suffix list
    // until it has the Public Suffix List, port plan D6).
    const siteOf = (hostname) => policyHost("site", { host: String(hostname || "") });
    async function storageState(options = {}, fromPage) {
      if (options === null || typeof options !== "object") throw new Error(`session.storageState: options: expected an object, got ${JSON.stringify(options)}`);
      const urls = options.urls ? [].concat(options.urls) : null;
      const page = fromPage || currentPage();
      let site = null;
      if (!options.all && !urls) {
        const url = page && !page._closed ? String(page.url()) : "";
        const hostname = /^https?:/i.test(url) ? new core.URL(url).hostname : "";
        if (!hostname) throw new Error(`session.storageState: the current tab (${url || "none"}) has no site to scope to; open the site first, or pass { all: true } for the whole profile or { urls: [...] }`);
        site = siteOf(hostname);
      }
      const inScope = (hostname) => site === null || siteOf(hostname) === site;
      // The cookies of the page's own data store (cookieScope).
      const cookies = (await session.call("cookies.get", { ...cookieScope(page), ...(urls ? { urls } : {}) })).filter((c) => inScope(String(c.domain || "")));
      // localStorage only from the open tabs in that store (storeTabs).
      const { targetIds } = await storeTabs(page);
      const origins = new Map();
      for (const page of [...session.pages.values()]) {
        if (page._closed || !targetIds.has(page._targetId)) continue;
        for (const frame of [page._mainFrame, ...page._frames.values()]) {
          if (frame._detached) continue;
          const r = await frame._call("agent", "() => { try { return { origin: location.origin, items: Object.entries(localStorage) }; } catch (e) { return null; } }", []).catch(() => null);
          if (!r || !r.origin || r.origin === "null") continue;
          if (urls && !urls.some((u) => new core.URL(u).origin === r.origin)) continue;
          if (!inScope(new core.URL(r.origin).hostname)) continue;
          origins.set(r.origin, r.items.map(([name, value]) => ({ name, value })));
        }
      }
      const state = { cookies, origins: [...origins].map(([origin, localStorage]) => ({ origin, localStorage })) };
      if (options.path) fs.writeFileSync(options.path, JSON.stringify(state, null, 2));
      return state;
    }
    // A page's cookie calls name its tab, so the driver uses that tab's data
    // store (a private tab's, or the session's proxy store), not another's.
    function cookieScope(page) {
      return page && !page._closed && typeof page._cookieScope === "function" ? page._cookieScope() : {};
    }
    // The data store the page's cookie calls use (`tabs.dataStore`), and the
    // open tabs in it. localStorage belongs to a store too, so storage state
    // reads and writes it only through those tabs, never through a tab on
    // the same origin in another store. A driver without `tabs.dataStore`
    // gets the page's own tab only.
    async function storeTabs(page) {
      const scope = cookieScope(page);
      let dataStore;
      try {
        ({ dataStore } = await session.call("tabs.dataStore", scope));
      } catch (e) {
        if (errCode(e) !== "unsupported") throw e;
        return { dataStore: undefined, targetIds: new Set(scope.targetId ? [scope.targetId] : []) };
      }
      const list = await session.call("tabs.list", { all: true });
      return { dataStore, targetIds: new Set(list.filter((t) => t.dataStore === dataStore).map((t) => t.targetId)) };
    }
    async function setStorageState(source, fromPage) {
      const state = typeof source === "string" ? JSON.parse(fs.readFileSync(source, "utf8")) : source;
      if (!state || typeof state !== "object" || (!Array.isArray(state.cookies) && !Array.isArray(state.origins))) {
        throw new Error("session.setStorageState: expected { cookies, origins } (Playwright's storage state) or a path to one");
      }
      const target = fromPage || currentPage();
      if (state.cookies && state.cookies.length) await session.call("cookies.set", { ...cookieScope(target), cookies: state.cookies });
      let restored = 0;
      let store = null;
      for (const { origin, localStorage } of state.origins || []) {
        if (!localStorage || !localStorage.length) continue;
        // An open tab on the origin in the page's data store takes the
        // items; otherwise a background tab of that store loads the origin,
        // takes them and closes.
        if (!store) store = await storeTabs(target);
        let page = [...session.pages.values()].find((p) => !p._closed && store.targetIds.has(p._targetId) && /^https?:/.test(p.url()) && new core.URL(p.url()).origin === origin);
        const temp = !page;
        if (temp) {
          page = await session.newPage(undefined, { background: true, dataStore: store.dataStore });
          await page.goto(origin + "/", { waitUntil: "domcontentloaded" });
        }
        try {
          await page._mainFrame._call("agent", "(items) => { for (const { name, value } of items) localStorage.setItem(name, value); }", [localStorage]);
          restored++;
        } finally {
          if (temp) await page.close().catch(() => {});
        }
      }
      return { cookies: (state.cookies || []).length, origins: restored };
    }

    session.agentStorage = { storageState, setStorageState };

    // ---- session members -------------------------------------------------------------
    Object.assign(sessionApi, {
      // Navigations, new tabs, fetch and sites tools may reach only these
      // domains; null clears this session's narrowing. { lock: true } fixes
      // it for the session. The host enforces it and never widens the user's.
      allowedDomains: (list, options) => setPolicy("allowed", "session.allowedDomains", list, options),
      prohibitedDomains: (list, options) => setPolicy("prohibited", "session.prohibitedDomains", list, options),
      blockIPAddresses(on, options) {
        if (on === undefined) return policyHost("get").blockIPs;
        return policyHost("set", { blockIPs: !!on, lock: !!(options && options.lock), title: "session.blockIPAddresses" }).blockIPs;
      },
      // cmux-next: the host blocks a navigation before its request and keeps
      // the log (policy op "log").
      blockedNavigations: () => policyHost("log"),
      // Playwright browser-context options for the tabs this session created:
      // { userAgent, extraHTTPHeaders, permissions, proxy }. null clears one.
      configure,
      configuration: () => JSON.parse(JSON.stringify(contextConfig)),
      storageState,
      setStorageState,
      downloads: () => downloads.map((d) => ({ ...d })),
      // Records each action of this session: trace.jsonl (method, URL, time),
      // a PNG after each action and navigation, and on stop() run.png, an
      // animated PNG of the run.
      record(options = {}) {
        if (recorder) throw new Error(`session.record: already recording to ${recorder.dir}; call stop() on it first`);
        const dir = options.dir ? path.resolve(String(options.dir)) : path.join(host.tmpdir, `record-${++recordCount}`);
        fs.mkdirSync(dir, { recursive: true });
        const r = { dir, trace: path.join(dir, "trace.jsonl"), screenshots: options.screenshots !== false, frames: 0, frameFiles: [], actions: 0, busy: false };
        fs.writeFileSync(r.trace, "");
        recorder = r;
        return {
          dir,
          async stop() {
            if (recorder === r) recorder = null;
            const result = { dir, trace: r.trace, actions: r.actions, frames: r.frameFiles.length, animation: null };
            if (r.frameFiles.length) {
              const apng = buildApng(r.frameFiles.map((f) => fs.readFileSync(f)), options.frameMs || 800);
              result.animation = path.join(dir, "run.png");
              fs.writeFileSync(result.animation, apng.bytes);
            }
            return result;
          },
        };
      },
    });

    // ---- search ------------------------------------------------------------------------
    async function search(query, options = {}) {
      if (typeof query !== "string" || !query.trim()) throw new Error(`search: query: expected a non-empty string, got ${JSON.stringify(query)}`);
      const engine = options.engine || "duckduckgo";
      const limit = options.limit === undefined ? 10 : options.limit;
      if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw new Error(`search: limit: expected 1 to 50, got ${JSON.stringify(limit)}`);
      if (engine === "google" && !options.endpoint) {
        if (!globals.sites || !globals.sites.googleSearch) throw new Error("search: Google search needs sites.googleSearch");
        return (await globals.sites.googleSearch.search(query, { limit })).map((r) => ({ title: r.title, url: r.url, snippet: r.snippet || "" }));
      }
      if (!ENGINES[engine]) throw new Error(`search: engine: expected one of duckduckgo, bing, google, got ${JSON.stringify(engine)}`);
      const template = options.endpoint || ENGINES[engine];
      const url = template.replace(/%s|\{query\}/, encodeURIComponent(query).replace(/%20/g, "+"));
      const res = await fetch(url, { headers: { "accept-language": "en-US,en;q=0.9" } });
      if (!res.ok && res.status !== 202) throw new Error(`search: ${engine} returned HTTP ${res.status}`);
      const html = await res.text();
      const page = await session.newPage(undefined, { background: true });
      try {
        const r = await page.evaluate(parseResults, { html, engine, base: url, limit });
        if (r.blocked) throw new Error(`search: ${engine} showed a CAPTCHA; cmux does not solve CAPTCHAs. Try another engine, or open ${url} with tabs.open() and let the user answer it`);
        return r.results;
      } finally {
        await page.close().catch(() => {});
      }
    }

    // ---- custom tools ------------------------------------------------------------------
    const registry = new Map();
    const TYPES = { string: "string", number: "number", boolean: "boolean", object: "object", array: "array", any: "any" };
    function checkArgs(name, params, args) {
      if (!params) return;
      if (args === null || typeof args !== "object" || Array.isArray(args)) throw new Error(`tools.${name}: expected an object of arguments, got ${JSON.stringify(args)}`);
      for (const [key, spec] of Object.entries(params)) {
        const optional = spec.endsWith("?");
        const type = spec.replace(/\?$/, "");
        const v = args[key];
        if (v === undefined) {
          if (!optional) throw new Error(`tools.${name}: ${key}: required (${type})`);
          continue;
        }
        const actual = Array.isArray(v) ? "array" : v === null ? "null" : typeof v;
        if (type !== "any" && actual !== type) throw new Error(`tools.${name}: ${key}: expected ${type}, got ${actual}`);
      }
      for (const key of Object.keys(args)) if (!(key in params)) throw new Error(`tools.${name}: unknown argument ${key}; expected ${Object.keys(params).join(", ") || "none"}`);
    }
    const tools = {
      // register(name, fn, { description, params: { key: "string" | "number?" ... }, domains })
      register(name, fn, options = {}) {
        if (typeof name !== "string" || !/^[A-Za-z_$][\w$]*$/.test(name) || name in tools) throw new Error(`tools.register: name: expected an identifier that is not ${Object.keys(tools).join(", ")}, got ${JSON.stringify(name)}`);
        if (typeof fn !== "function") throw new Error(`tools.register: ${name}: expected a function`);
        const params = options.params || null;
        if (params) for (const [k, t] of Object.entries(params)) if (typeof t !== "string" || !TYPES[t.replace(/\?$/, "")]) throw new Error(`tools.register: ${name}: params.${k}: expected one of ${Object.keys(TYPES).join(", ")} (add ? when optional), got ${JSON.stringify(t)}`);
        const domains = options.domains ? options.domains.map((d) => parsePattern(d, "tools.register")) : null;
        const entry = { name, fn, description: String(options.description || ""), params, domains };
        if (registry.has(name)) delete tools[registry.get(name).name];
        registry.set(name, entry);
        Object.defineProperty(tools, name, { value: (args) => tools.call(name, args), enumerable: false, configurable: true });
        return tools.describe(name);
      },
      describe(name) {
        const e = registry.get(name);
        if (!e) throw new Error(`tools: no tool ${JSON.stringify(name)}; see tools.list()`);
        return { name: e.name, description: e.description, params: e.params, domains: e.domains && e.domains.map((d) => d.raw) };
      },
      list: () => [...registry.keys()].map((n) => tools.describe(n)),
      async call(name, args = {}) {
        const e = registry.get(name);
        if (!e) throw new Error(`tools: no tool ${JSON.stringify(name)}; see tools.list()`);
        checkArgs(name, e.params, args);
        const page = currentPage();
        if (e.domains && !e.domains.some((d) => urlMatches(page.url(), d, false))) throw new Error(`tools.${name}: available only on ${e.domains.map((d) => d.raw).join(", ")}; the current tab is ${page.url()}`);
        return e.fn(args, { page, session: sessionApi, tabs: ctx.tabs });
      },
      unregister(name) {
        if (!registry.has(name)) return false;
        registry.delete(name);
        delete tools[name];
        return true;
      },
    };

    Object.assign(globals, { secret, secrets, search, tools });
  }

  // ---------------------------------------------------------------------------
  // Page and Locator additions.

  const P = core.Page.prototype;

  async function frameMarkdown(page, frame, opts, depth, budget) {
    const r = await agentCall(frame, markdownOfFrame, opts);
    let text = r.blocks.join("\n\n");
    if (!r.frames.length) return text;
    let children = null;
    try {
      const found = await page._session.call("frame.contentFrames", { targetId: page._targetId, frameId: frame._id || undefined, elements: r.frames });
      children = found.map((f) => (f ? page._frameFor(f.frameId, frame) : null));
    } catch (e) {
      if (errCode(e) !== "unsupported") throw e;
      children = [];
      for (const h of r.frames) children.push(await frame._contentFrame(h).catch(() => null));
    }
    const parts = await Promise.all(children.map((child) => (child && depth < 6 && budget.frames-- > 0 ? frameMarkdown(page, child, { ...opts, main: false }, depth + 1, budget).catch(() => "") : "")));
    return text.replace(/\u0000F(\d+)\u0000/g, (_, i) => parts[Number(i)] || "").replace(/\n{3,}/g, "\n\n").trim();
  }

  // The page as Markdown: headings, paragraphs, lists, tables, code, links,
  // form values (never passwords), iframes and shadow roots in place.
  // { main: true } keeps the main content (<main>, the one <article>, else
  // the page without navigation, banner, footer and sidebars). { links: false }
  // drops link URLs, { images: true } keeps images. { start, maxChars } cut at
  // block boundaries; a cut says where to continue.
  P.markdown = async function (options = {}) {
    if (options === null || typeof options !== "object") throw new Error(`page.markdown: options: expected an object, got ${JSON.stringify(options)}`);
    const opts = { main: !!options.main, links: options.links !== false, images: !!options.images };
    await this._syncInfo().catch(() => {});
    const full = (await frameMarkdown(this, this._mainFrame, opts, 0, { frames: 100 })) + "\n";
    const start = options.start || 0;
    const max = options.maxChars === undefined ? Infinity : options.maxChars;
    if (!Number.isInteger(start) || start < 0) throw new Error(`page.markdown: start: expected a non-negative integer, got ${JSON.stringify(options.start)}`);
    if (!(max > 0)) throw new Error(`page.markdown: maxChars: expected a positive number, got ${JSON.stringify(options.maxChars)}`);
    if (start === 0 && full.length <= max) return full;
    if (start >= full.length) throw new Error(`page.markdown: start ${start} is past the end (${full.length} characters)`);
    let end = Math.min(full.length, start + max);
    if (end < full.length) {
      const cut = full.lastIndexOf("\n\n", end);
      const line = full.lastIndexOf("\n", end);
      end = cut > start ? cut + 2 : line > start ? line + 1 : end;
    }
    let text = full.slice(start, end);
    // A cut inside a table repeats its header row.
    const before = full.slice(0, start);
    const tableStart = before.lastIndexOf("\n\n") + 2;
    if (start > 0 && /^\|/.test(text) && /^\|/.test(full.slice(tableStart))) {
      const header = full.slice(tableStart).split("\n").slice(0, 2);
      if (header.length === 2 && /^\|( --- \|)+$/.test(header[1]) && full.slice(tableStart, start).includes("\n")) text = header.join("\n") + "\n" + text;
    }
    const commas = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    const tail = end < full.length ? `; continue with page.markdown({ start: ${end}${options.maxChars !== undefined ? `, maxChars: ${options.maxChars}` : ""}${options.main ? ", main: true" : ""} })` : "";
    return text.replace(/\n*$/, "\n") + `\n<!-- characters ${commas(start)} to ${commas(end)} of ${commas(full.length)}${tail} -->\n`;
  };

  // Structured data by selectors, no model: page.extract({ $: ".product",
  // name: "h3", price: ".price", url: "a@href" }). { scope: ref | locator }
  // limits it to one element; { limit } caps each list (1000).
  P.extract = async function (schema, options = {}) {
    let frame = this._mainFrame;
    let scope = null;
    if (options.scope) {
      const loc = typeof options.scope === "string" ? this.locator(options.scope) : options.scope;
      if (!(loc instanceof core.Locator)) throw new Error("page.extract: scope: expected a ref, selector or locator");
      const r = await loc._resolveOne(true);
      if (!r) throw new Error(`page.extract: scope ${loc} matched nothing`);
      frame = r.frame;
      scope = r.handle;
    }
    const unpair = (v) => {
      if (Array.isArray(v)) return v.map(unpair);
      if (v && typeof v === "object" && Array.isArray(v.__cmuxPairs)) {
        const o = {};
        for (const [k, x] of v.__cmuxPairs) o[k] = unpair(x);
        return o;
      }
      return v;
    };
    const pair = (v) => {
      if (Array.isArray(v)) return v.map(pair);
      if (v && typeof v === "object") return { __cmuxPairs: Object.entries(v).map(([k, x]) => [k, pair(x)]) };
      return v;
    };
    return unpair(await agentCall(frame, extractInFrame, pair(schema), { scope, limit: options.limit }));
  };

  // Text matches with surrounding context and the ref of the element each is
  // in: { total, matches: [{ match, context, ref }] }.
  P.searchText = async function (pattern, options = {}) {
    if (typeof pattern !== "string" || !pattern) throw new Error(`page.searchText: pattern: expected a non-empty string, got ${JSON.stringify(pattern)}`);
    let frame = this._mainFrame;
    let scope = null;
    if (options.scope) {
      const loc = typeof options.scope === "string" ? this.locator(options.scope) : options.scope;
      const r = await loc._resolveOne(true);
      if (!r) throw new Error(`page.searchText: scope ${loc} matched nothing`);
      frame = r.frame;
      scope = r.handle;
    }
    const r = await agentCall(frame, searchTextInFrame, { pattern, regex: !!options.regex, caseSensitive: !!options.caseSensitive, context: options.context === undefined ? 60 : options.context, limit: options.limit === undefined ? 25 : options.limit, scope });
    const matches = [];
    for (const m of r.matches) {
      let ref = null;
      if (m.handle) ref = await this._refForHandle(frame, m.handle).catch(() => null);
      matches.push({ match: m.match, context: m.context, ref });
    }
    return { total: r.total, matches };
  };

  const targetLocator = (page, target, title) => {
    if (typeof target === "string") return page.locator(target);
    if (target instanceof core.Locator) return target;
    throw new Error(`${title}: expected a ref, selector or locator, got ${JSON.stringify(target)}`);
  };

  // Scrolls the first element with this text into view; returns its ref.
  P.scrollToText = async function (text, options = {}) {
    if (typeof text !== "string" || !text) throw new Error(`page.scrollToText: text: expected a non-empty string, got ${JSON.stringify(text)}`);
    const loc = this.getByText(text, { exact: !!options.exact }).first();
    await loc.scrollIntoViewIfNeeded({ timeout: options.timeout === undefined ? 5000 : options.timeout });
    const r = await loc._resolveOne(false);
    return r ? this._refForHandle(r.frame, r.handle) : null;
  };

  // Where the page, or a scrollable element, is scrolled:
  // { x, y, viewportHeight, scrollHeight, pagesAbove, pagesBelow }.
  P.scrollInfo = async function (target) {
    if (target === undefined) return agentCall(this._mainFrame, scrollInfoInFrame, null);
    const r = await targetLocator(this, target, "page.scrollInfo")._resolveOne(true);
    if (!r) throw new Error(`page.scrollInfo: ${target} matched nothing`);
    return agentCall(r.frame, scrollInfoInFrame, r.handle);
  };

  // Scrolls by pages with real wheel events, over the page or an element
  // (negative pages scroll up); returns scrollInfo afterwards.
  P.scroll = async function (options = {}) {
    const pages = options.pages === undefined ? 1 : options.pages;
    if (typeof pages !== "number" || !Number.isFinite(pages) || pages === 0) throw new Error(`page.scroll: pages: expected a non-zero number, got ${JSON.stringify(options.pages)}`);
    let point;
    let info;
    if (options.target !== undefined) {
      const loc = targetLocator(this, options.target, "page.scroll");
      await loc.scrollIntoViewIfNeeded();
      const box = await loc.boundingBox();
      if (!box) throw new Error(`page.scroll: ${options.target} is not visible`);
      point = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
      info = await this.scrollInfo(options.target);
    } else {
      info = await this.scrollInfo();
      const vp = await this._mainFrame._call("agent", "() => ({ w: innerWidth, h: innerHeight })", []);
      point = { x: vp.w / 2, y: vp.h / 2 };
    }
    // A scroll position set by script (scrollIntoView, scrollToText) reaches
    // WebKit's scrolling tree at the next rendering update; a wheel sent
    // before it starts from the old position and is dropped.
    await this._mainFrame._call("agent", "() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))", []);
    await this.mouse.move(point.x, point.y);
    await this.mouse.wheel(0, Math.round(pages * info.viewportHeight));
    let last = null;
    for (let i = 0; i < 20; i++) {
      const now = options.target !== undefined ? await this.scrollInfo(options.target) : await this.scrollInfo();
      if (last && now.y === last.y && now.y !== info.y) return now;
      last = now;
      await this._session.sleep(50);
    }
    return last;
  };

  // The options of a native <select> or an ARIA combobox, listbox or menu:
  // [{ index, label, value, selected, disabled, ref? }]. An ARIA popup must
  // be open (its options in the page).
  P.dropdownOptions = async function (target) {
    const r = await targetLocator(this, target, "page.dropdownOptions")._resolveOne(true);
    if (!r) throw new Error(`page.dropdownOptions: ${target} matched nothing`);
    const d = await agentCall(r.frame, dropdownInFrame, r.handle);
    if (d.kind === "none") throw new Error(`page.dropdownOptions: ${target} is not a <select> and controls no listbox or menu; open the drop-down first, then pass it or its listbox`);
    if (d.kind === "aria" && !d.options.length) throw new Error(`page.dropdownOptions: the listbox of ${target} shows no options; click it to open it, then call again`);
    const out = [];
    for (const o of d.options) {
      const row = { index: o.index, label: o.label, value: o.value, selected: o.selected, disabled: o.disabled };
      if (o.handle) row.ref = await this._refForHandle(r.frame, o.handle).catch(() => null);
      out.push(row);
    }
    return out;
  };

  // Boxes and ref labels over elements, until hideHighlight() or the next
  // highlight: every interactive element without targets, else the given refs or locators. Returns the count.
  P.highlight = async function (targets) {
    await this.hideHighlight();
    if (targets === undefined) {
      this._highlightClear = await ns.snapshot.annotate(this);
      return null;
    }
    const byFrame = new Map();
    for (const t of [].concat(targets)) {
      const r = await targetLocator(this, t, "page.highlight")._resolveAll();
      if (!r) continue;
      for (const h of r.handles) {
        const ref = await this._refForHandle(r.frame, h);
        if (!byFrame.has(r.frame)) byFrame.set(r.frame, []);
        byFrame.get(r.frame).push([ref.replace(/^f\d+/, ""), ref]);
      }
    }
    let n = 0;
    for (const [frame, pairs] of byFrame) n += await frame._agent("annotate", pairs);
    const frames = [...byFrame.keys()];
    this._highlightClear = async () => {
      for (const f of frames) await f._agent("clearAnnotations").catch(() => {});
    };
    return n;
  };
  P.hideHighlight = async function () {
    const clear = this._highlightClear;
    this._highlightClear = null;
    if (clear) await clear();
  };
  core.Locator.prototype.highlight = async function () {
    await this._page.highlight(this);
  };

  // Playwright's context.storageState / setStorageState names.
  const context = P.context;
  P.context = function () {
    const c = context.call(this);
    const storage = this._session.agentStorage;
    // Scoped like session.storageState, to this page's site.
    if (storage) Object.assign(c, { storageState: (options = {}) => storage.storageState(options, this), setStorageState: (source) => storage.setStorageState(source, this) });
    return c;
  };

  // Multi-label public suffixes common enough to matter; any other host is
  // treated as having a one-label suffix (example.com). This is a compact
  // stand-in for the Public Suffix List: an unlisted multi-label suffix
  // (e.g. a regional .gov.xx) scopes to the suffix plus one label too few.
  const MULTI_SUFFIXES = new Set(("co.uk org.uk ac.uk gov.uk me.uk ltd.uk plc.uk net.uk co.jp ne.jp or.jp ac.jp go.jp " +
    "co.at or.at com.au net.au org.au edu.au gov.au co.nz org.nz govt.nz co.in net.in org.in gov.in ac.in com.br net.br org.br gov.br " +
    "com.cn net.cn org.cn gov.cn edu.cn com.hk org.hk com.tw org.tw co.kr or.kr com.sg edu.sg com.mx org.mx co.za org.za " +
    "com.tr com.ar com.co com.pe com.my com.ph com.vn co.id co.il co.th com.ua com.pl com.es com.sa com.eg com.ng " +
    "github.io gitlab.io pages.dev workers.dev vercel.app netlify.app herokuapp.com web.app firebaseapp.com " +
    "appspot.com blogspot.com azurewebsites.net cloudfront.net amazonaws.com s3.amazonaws.com fly.dev onrender.com " +
    "glitch.me repl.co ngrok.io ngrok-free.app trycloudflare.com").split(" "));
  function registrableDomain(hostname) {
    const h = String(hostname || "").toLowerCase().replace(/^\.+/, "").replace(/\.$/, "");
    if (!h || h.startsWith("[") || /^\d+(\.\d+){3}$/.test(h) || !h.includes(".")) return h;
    const labels = h.split(".");
    for (let i = 1; i < labels.length; i++) {
      if (MULTI_SUFFIXES.has(labels.slice(i).join("."))) return labels.slice(i - 1).join(".");
    }
    return labels.slice(-2).join(".");
  }

  ns.agentTools = { install, urlMatches, parsePattern, normalizeHost, crc32, buildApng, pngChunks, parseResults, markdownOfFrame, registrableDomain };
})(typeof globalThis !== "undefined" ? globalThis : this);
