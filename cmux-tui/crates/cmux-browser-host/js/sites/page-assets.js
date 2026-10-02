// sites.pageAssets: the file assets a rendered page uses (images, fonts,
// stylesheets, video, scripts) and its inline SVGs, and a bundle of them
// downloaded through the signed-in session (ChatGPT for Chrome's pageAssets).
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL } = root.CmuxBrowserRepl.core;
  const KINDS = ["image", "font", "stylesheet", "video", "script", "other"];

  function inventory(arg) {
    const found = new Map();
    const kindOf = (url, hint) => {
      if (hint) return hint;
      const p = url.split(/[?#]/)[0].toLowerCase();
      if (/^data:image\//.test(url) || /\.(png|jpe?g|gif|webp|avif|svg|ico|bmp|tiff?)$/.test(p)) return "image";
      if (/^data:(font|application\/(x-)?font)/.test(url) || /\.(woff2?|ttf|otf|eot)$/.test(p)) return "font";
      if (/\.css$/.test(p)) return "stylesheet";
      if (/\.(mp4|webm|mov|m4v|m3u8|ogv)$/.test(p)) return "video";
      if (/\.(m?js)$/.test(p)) return "script";
      return "other";
    };
    const add = (raw, source, hint) => {
      if (!raw) return;
      let url;
      try {
        url = new URL(raw, document.baseURI).href;
      } catch (e) {
        return;
      }
      if (!/^(https?:|data:)/.test(url)) return;
      let a = found.get(url);
      if (!a) {
        const name = url.startsWith("data:") ? "inline-" + (found.size + 1) : decodeURIComponent(url.split(/[?#]/)[0].split("/").pop() || new URL(url).hostname);
        a = { kind: kindOf(url, hint), name, url, sources: [] };
        found.set(url, a);
      }
      if (a.sources.length < 5 && !a.sources.some((s) => s.kind === source.kind && s.property === source.property)) a.sources.push(source);
    };
    const srcset = (v) => (v || "").split(",").map((s) => s.trim().split(/\s+/)[0]).filter(Boolean);
    for (const img of document.images) {
      add(img.currentSrc || img.src, { kind: "attribute", property: "src" }, "image");
      for (const u of srcset(img.getAttribute("srcset"))) add(u, { kind: "attribute", property: "srcset" }, "image");
    }
    for (const s of document.querySelectorAll("picture source[srcset]")) for (const u of srcset(s.getAttribute("srcset"))) add(u, { kind: "attribute", property: "srcset" }, "image");
    for (const v of document.querySelectorAll("video")) {
      add(v.currentSrc || v.getAttribute("src"), { kind: "attribute", property: "src" }, "video");
      add(v.getAttribute("poster"), { kind: "attribute", property: "poster" }, "image");
      for (const s of v.querySelectorAll("source[src]")) add(s.getAttribute("src"), { kind: "attribute", property: "src" }, "video");
    }
    for (const l of document.querySelectorAll("link[href]")) {
      const rel = (l.getAttribute("rel") || "").toLowerCase();
      if (/stylesheet/.test(rel)) add(l.href, { kind: "attribute", property: "href" }, "stylesheet");
      else if (/icon/.test(rel)) add(l.href, { kind: "attribute", property: "href" }, "image");
      else if (/preload|prefetch/.test(rel)) add(l.href, { kind: "attribute", property: "href" }, { font: "font", image: "image", style: "stylesheet", script: "script", video: "video" }[l.getAttribute("as")] || null);
    }
    for (const s of document.querySelectorAll("script[src]")) add(s.src, { kind: "attribute", property: "src" }, "script");
    const els = document.querySelectorAll("body *");
    for (let i = 0; i < els.length && i < arg.maxElements; i++) {
      const cs = getComputedStyle(els[i]);
      for (const prop of ["background-image", "mask-image", "list-style-image", "border-image-source"]) {
        const v = cs.getPropertyValue(prop);
        if (v && v !== "none") for (const m of v.matchAll(/url\(["']?([^"')]+)["']?\)/g)) add(m[1], { kind: "computedStyle", property: prop }, "image");
      }
    }
    for (const sheet of document.styleSheets) {
      let rules;
      try {
        rules = sheet.cssRules;
      } catch (e) {
        continue;
      }
      for (const r of rules || []) if (r.type === 5 && r.style) for (const m of (r.style.getPropertyValue("src") || "").matchAll(/url\(["']?([^"')]+)["']?\)/g)) add(new URL(m[1], sheet.href || document.baseURI).href, { kind: "computedStyle", property: "@font-face src" }, "font");
    }
    for (const e of performance.getEntriesByType("resource")) {
      const hint = { img: "image", css: "stylesheet", link: null, script: "script", video: "video" }[e.initiatorType];
      if (e.initiatorType === "css" || e.initiatorType === "img" || e.initiatorType === "link" || e.initiatorType === "video") add(e.name, { kind: "resource" }, e.initiatorType === "css" && !/\.css(\?|$)/.test(e.name) ? null : hint);
    }
    const svgs = [...document.querySelectorAll("svg")].filter((s) => !s.parentElement || !s.parentElement.closest("svg")).slice(0, arg.maxSvgs);
    const inlineSvgs = svgs.map((s, i) => {
      const label = s.getAttribute("aria-label") || (s.querySelector("title") || {}).textContent || s.id || "svg-" + (i + 1);
      const markup = s.outerHTML;
      return { name: String(label).trim().slice(0, 60), markup: markup.length > arg.maxSvgChars ? markup.slice(0, arg.maxSvgChars) + "<!-- truncated -->" : markup };
    });
    return { pageUrl: location.href, assets: [...found.values()], inlineSvgs };
  }

  const EXT = { "image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp", "image/avif": ".avif", "image/svg+xml": ".svg", "image/x-icon": ".ico", "image/vnd.microsoft.icon": ".ico", "font/woff2": ".woff2", "font/woff": ".woff", "font/ttf": ".ttf", "font/otf": ".otf", "text/css": ".css", "video/mp4": ".mp4", "video/webm": ".webm", "text/javascript": ".js", "application/javascript": ".js" };

  S.register(
    "pageAssets",
    (t) => {
      const inventories = new Map();
      let n = 0;
      return {
        // { id, pageUrl, assets: [{ id, kind, name, url, sources }], inlineSvgs: [{ id, name, markup }], summary }.
        // Load the state that matters first (scroll, open menus); list() sees what is loaded now.
        async list(page, options = {}) {
          const p = page || t.currentPage();
          const raw = await p.evaluate(inventory, { maxElements: options.maxElements || 5000, maxSvgs: options.maxSvgs || 200, maxSvgChars: options.maxSvgChars || 20000 });
          const id = `inv-${++n}`;
          const assets = raw.assets.map((a, i) => ({ id: `a${i + 1}`, ...a }));
          const inlineSvgs = raw.inlineSvgs.map((s, i) => ({ id: `svg${i + 1}`, ...s }));
          const byKind = {};
          for (const a of assets) byKind[a.kind] = (byKind[a.kind] || 0) + 1;
          const inv = { id, pageUrl: raw.pageUrl, assets, inlineSvgs, summary: { byKind, inlineSvgCount: inlineSvgs.length, totalCount: assets.length } };
          inventories.set(id, inv);
          return inv;
        },
        // Downloads assets of a list() inventory into a directory:
        // { directoryPath, manifestPath, assets: [{ id, kind, name, url, path, contentType }], failures, summary }.
        // { kinds } or { assetIds } narrow it (default: images, fonts, stylesheets, video); inline SVGs are written with images.
        async bundle(inv, options = {}) {
          const started = t.now();
          const inventory_ = typeof inv === "string" ? inventories.get(inv) : inv && inv.id ? inventories.get(inv.id) || inv : null;
          if (!inventory_) throw new S.SiteError("invalid", `pageAssets.bundle: expected an inventory from pageAssets.list() or its id, got ${JSON.stringify(inv)}`);
          const kinds = options.kinds || ["image", "font", "stylesheet", "video"];
          for (const k of kinds) if (!KINDS.includes(k)) throw new S.SiteError("invalid", `pageAssets.bundle: kinds: expected ${KINDS.join(", ")}, got ${JSON.stringify(k)}`);
          const pick = options.assetIds ? inventory_.assets.filter((a) => options.assetIds.includes(a.id)) : inventory_.assets.filter((a) => kinds.includes(a.kind));
          const dir = t.outputDir(options, "assets");
          const used = new Set();
          const fileName = (name, ext) => {
            let base = String(name).replace(/[^\w.@-]+/g, "_").slice(0, 80) || "asset";
            if (ext && !/\.[a-z0-9]{1,6}$/i.test(base)) base += ext;
            let f = base;
            for (let i = 2; used.has(f); i++) f = base.replace(/(\.[^.]*)?$/, `-${i}$1`);
            used.add(f);
            return f;
          };
          const assets = [];
          const failures = [];
          const one = async (a) => {
            try {
              let bytes;
              let type = null;
              if (a.url.startsWith("data:")) {
                const m = /^data:([^;,]*)(;base64)?,(.*)$/s.exec(a.url);
                if (!m) throw new Error("malformed data URL");
                type = m[1] || null;
                bytes = m[2] ? t.Buffer.from(m[3], "base64") : t.Buffer.from(decodeURIComponent(m[3]), "utf8");
              } else {
                const r = await t.fetch(a.url);
                if (!r.ok) throw new Error(`HTTP ${r.status}`);
                type = (r.headers.get("content-type") || "").split(";")[0] || null;
                bytes = t.Buffer.from(await r.arrayBuffer());
              }
              const file = t.path.join(dir, fileName(a.name, EXT[type] || ""));
              t.fs.writeFileSync(file, bytes);
              assets.push({ id: a.id, kind: a.kind, name: a.name, url: a.url, path: file, contentType: type });
            } catch (e) {
              failures.push({ id: a.id, name: a.name, url: a.url, contentType: null, reason: String((e && e.message) || e) });
            }
          };
          for (let i = 0; i < pick.length; i += 4) await Promise.all(pick.slice(i, i + 4).map(one));
          if (!options.assetIds && kinds.includes("image")) {
            for (const s of inventory_.inlineSvgs) {
              const file = t.path.join(dir, fileName(s.name, ".svg"));
              t.fs.writeFileSync(file, /xmlns=/.test(s.markup) ? s.markup : s.markup.replace(/^<svg/, '<svg xmlns="http://www.w3.org/2000/svg"'));
              assets.push({ id: s.id, kind: "image", name: s.name, url: null, path: file, contentType: "image/svg+xml" });
            }
          }
          const manifestPath = t.path.join(dir, "manifest.json");
          const summary = { requestedCount: pick.length, downloadedCount: assets.length, failedCount: failures.length, elapsedMs: t.now() - started };
          t.fs.writeFileSync(manifestPath, JSON.stringify({ pageUrl: inventory_.pageUrl, assets, failures, summary }, null, 2));
          return { directoryPath: dir, manifestPath, assets, failures, summary };
        },
      };
    },
    { summary: "Inventory of a page's images, fonts, stylesheets, video, scripts, inline SVGs; download bundle" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
