// sites.googleSearch: structured Google web results through the signed-in
// session: Google's basic results page from the session's fetch (its links
// carry the destination), else the full page in a background tab. Searches
// run one at a time with a short gap, since bursts make Google show a CAPTCHA.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URLSearchParams } = root.CmuxBrowserRepl.core;
  const GAP_MS = 1200;

  const DATED = /^(\d+ (?:seconds?|minutes?|hours?|days?|weeks?|months?|years?) ago|[A-Z][a-z]{2} \d{1,2}, \d{4})\s+[\u2014-]\s+/;

  // Parses Google's basic results page (what the session's fetch receives):
  // each result is a /url?q=<destination> link around an h3. Runs in a blank
  // tab for its DOM parser.
  function readBasic(arg) {
    const doc = new DOMParser().parseFromString(arg.html, "text/html");
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const google = (u) => /(^|\.)google\.[a-z.]+$/.test(u.hostname) && !/^(docs|sites|developers|support|cloud|blog)\./.test(u.hostname);
    const target = (a) => {
      try {
        const u = new URL(a.getAttribute("href"), "https://www.google.com");
        const dest = new URL(u.pathname === "/url" ? u.searchParams.get("q") || u.searchParams.get("url") || "" : u.href);
        return /^https?:$/.test(dest.protocol) && !google(dest) ? dest.href : null;
      } catch (e) {
        return null;
      }
    };
    const dated = new RegExp(arg.dated);
    const out = [];
    const seen = new Set();
    for (const a of doc.querySelectorAll('a[href^="/url?"], a[href^="http"]')) {
      const h3 = a.querySelector("h3");
      const url = h3 && target(a);
      if (!url || seen.has(url)) continue;
      seen.add(url);
      const r = { title: clean(h3.textContent), url };
      const crumb = [...a.querySelectorAll("div, span, cite")].filter((e) => !e.closest("h3") && !e.querySelector("div, span, cite")).map((e) => clean(e.textContent)).find((x) => x && x !== r.title);
      if (crumb) r.displayUrl = crumb;
      const block = a.closest("div.Gx5Zad, div.xpd, div.g") || (a.parentElement && a.parentElement.parentElement) || a;
      const leaves = [...block.querySelectorAll("div, span")].filter((e) => !a.contains(e) && !e.querySelector("div, span") && clean(e.textContent).length > 20);
      let snippet = leaves.map((e) => clean(e.textContent)).sort((x, y) => y.length - x.length)[0] || "";
      const d = dated.exec(snippet);
      if (d) {
        r.publishedAtText = d[1];
        snippet = snippet.slice(d[0].length);
      }
      if (snippet) r.snippet = snippet;
      const links = [...block.querySelectorAll("a[href]")].filter((x) => x !== a && !x.querySelector("h3") && clean(x.textContent)).map((x) => ({ title: clean(x.textContent), url: target(x) })).filter((x) => x.url && x.url !== url && x.title.length < 80);
      if (links.length) r.sitelinks = links.slice(0, 6);
      out.push(r);
      if (out.length >= arg.limit) break;
    }
    return out;
  }

  // Parses the JavaScript results page in a tab (the fallback). Blocks are
  // div[data-rpos]; Google may link results through an opaque /goto
  // redirect, which is kept as the url with the shown address as displayUrl.
  function readResults(arg) {
    if (/\/sorry\//.test(location.pathname) || document.querySelector("form#captcha-form, #recaptcha")) return { blocked: true };
    const external = (a) => {
      try {
        let u = new URL(a.href, location.href);
        if (/(^|\.)google\.[a-z.]+$/.test(u.hostname) && u.pathname === "/goto") return u.href;
        if (/(^|\.)google\.[a-z.]+$/.test(u.hostname) && u.pathname === "/url") u = new URL(u.searchParams.get("q") || u.searchParams.get("url") || "", location.href);
        if (!/^https?:$/.test(u.protocol)) return null;
        if (/(^|\.)google\.[a-z.]+$/.test(u.hostname) && !/^(docs|sites|developers|support|cloud|blog)\./.test(u.hostname)) return null;
        return u.href;
      } catch (e) {
        return null;
      }
    };
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const dated = new RegExp(arg.dated);
    let blocks = [...document.querySelectorAll("#search div[data-rpos], #rso div[data-rpos]")].filter((b) => !b.parentElement.closest("div[data-rpos]"));
    if (!blocks.length) blocks = [...document.querySelectorAll("#rso a h3, #search a h3")].map((h) => h.closest("#rso > div, #search div.g") || h.closest("a").parentElement);
    const results = [];
    const seen = new Set();
    for (const b of blocks) {
      const h3 = b.querySelector("a h3");
      const a = h3 && h3.closest("a");
      const url = a && external(a);
      if (!url || seen.has(url)) continue;
      seen.add(url);
      const r = { title: clean(h3.textContent), url };
      const cite = a.querySelector("cite") || b.querySelector("cite");
      if (cite) r.displayUrl = clean(cite.textContent);
      const site = [...a.querySelectorAll("span")].map((s) => clean(s.textContent)).find((s) => s && s !== r.title && !(cite && cite.textContent.includes(s)) && !/^https?:\/\//.test(s) && !/^\u203a/.test(s));
      if (site) r.sourceName = site;
      const snippetEl = b.querySelector("[data-sncf], [data-snf]") || [...b.querySelectorAll("div, span")].reverse().find((d) => !d.contains(a) && !a.contains(d) && clean(d.textContent).length > 40 && d.children.length < 6);
      let snippet = snippetEl ? clean(snippetEl.textContent) : "";
      const d = dated.exec(snippet);
      if (d) {
        r.publishedAtText = d[1];
        snippet = snippet.slice(d[0].length);
      }
      if (snippet) r.snippet = snippet;
      const links = [...b.querySelectorAll("a[href]")].filter((x) => x !== a && clean(x.textContent) && !x.querySelector("h3")).map((x) => ({ title: clean(x.textContent), url: external(x) })).filter((x) => x.url && x.url !== url && x.title.length < 80);
      if (links.length) r.sitelinks = links.slice(0, 6);
      results.push(r);
      if (results.length >= arg.limit) break;
    }
    return { results };
  }

  S.register(
    "googleSearch",
    (t) => {
      let queue = Promise.resolve();
      let last = 0;
      return {
        // [{ title, url, displayUrl, sourceName, publishedAtText, snippet, sitelinks }].
        // Options: limit (10), start (offset: 10 = page 2), language ("en"),
        // country ("us"), safeSearch ("active" | "off"), time ("day" | "week" | "month" | "year").
        search(query, options = {}) {
          if (!query || typeof query !== "string") throw new S.SiteError("invalid", `googleSearch.search: query: expected a string, got ${JSON.stringify(query)}`);
          const limit = options.limit === undefined ? 10 : options.limit;
          if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new S.SiteError("invalid", `googleSearch.search: limit: expected 1 to 100, got ${JSON.stringify(limit)}`);
          const times = { day: "d", week: "w", month: "m", year: "y" };
          if (options.time !== undefined && !times[options.time]) throw new S.SiteError("invalid", `googleSearch.search: time: expected day, week, month or year, got ${JSON.stringify(options.time)}`);
          const q = new URLSearchParams({ q: query, hl: options.language || "en" });
          if (options.country) q.set("gl", options.country);
          if (options.start) q.set("start", String(options.start));
          if (limit > 10) q.set("num", String(limit));
          if (options.safeSearch) q.set("safe", options.safeSearch === "off" ? "off" : "active");
          if (options.time) q.set("tbs", `qdr:${times[options.time]}`);
          const captcha = () => new S.SiteError("captcha", "googleSearch.search: Google showed a CAPTCHA (unusual traffic). cmux does not solve CAPTCHAs; open https://www.google.com/search with tabs.open() and let the user answer it, then retry.");
          const run = async () => {
            const wait = last + GAP_MS - t.now();
            if (wait > 0) await t.sleep(wait);
            try {
              // The session's fetch gets Google's basic results page, whose
              // links carry the destination; parse it in a blank tab.
              const r = await t.fetch(`https://www.google.com/search?${q}`);
              if (/\/sorry\//.test(r.url) || r.status === 429) throw captcha();
              const html = r.ok ? await r.text() : "";
              if (/id="captcha-form"|g-recaptcha/.test(html)) throw captcha();
              const basic = html ? await t.withTab("about:blank", (page) => page.evaluate(readBasic, { html, limit, dated: DATED.source })) : [];
              if (basic.length) return basic;
              // Otherwise read the full results page in a tab.
              return await t.withTab(`https://www.google.com/search?${q}`, async (page) => {
                await t.waitIn(page, () => !!(document.querySelector("#search, #rso, form#captcha-form, #recaptcha") || /\/sorry\//.test(location.pathname)), undefined, { what: "Google results", name: "googleSearch.search" });
                const res = await page.evaluate(readResults, { limit, dated: DATED.source });
                if (res.blocked) throw captcha();
                return res.results;
              });
            } finally {
              last = t.now();
            }
          };
          const p = queue.then(run, run);
          queue = p.catch(() => {});
          return p;
        },
      };
    },
    { summary: "Structured Google web results (sequential, CAPTCHA reported, never solved)" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
