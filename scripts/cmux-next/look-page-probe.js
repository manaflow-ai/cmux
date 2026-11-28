// hot-verify look's page probe (look_page_log.py): the first script of the agent pane's index.html in a look's
// web overlay. It sends the page's console, uncaught errors and a DOM snapshot of the pane (New Tab included) to
// the look's sink, which web-dev.json names as the copy's `server`. The pane's CSP allows scripts from 'self' only
// and no fetch (connect-src 'none'), so each message is a <script src> GET of /agent-pane/__look_probe/... on the
// pane's own origin, which the app's scheme handler forwards to the server; everything else the sink answers 404,
// and the app serves it from the overlay as before.
(function () {
  "use strict";
  if (window.__cmuxLookProbe) return;
  window.__cmuxLookProbe = true;
  var PATH = "/agent-pane/__look_probe/";
  var CHUNK = 6000; // base64url characters per request
  var MAX_HTML = 400000; // characters of #root's HTML in one snapshot
  var page = Math.random().toString(36).slice(2, 10);
  var queue = [];
  var busy = false;
  var seq = 0;

  function pump() {
    if (busy || !queue.length) return;
    busy = true;
    var url = queue.shift();
    var s = document.createElement("script");
    s.src = url;
    s.onload = s.onerror = function () {
      s.remove();
      busy = false;
      pump();
    };
    (document.head || document.documentElement).appendChild(s);
  }

  // KIND (console | dom) and one JSON message, cut into chunks the sink joins by page, id and index. The JSON
  // goes as base64url: the scheme handler forwards some queries percent-encoded once and some twice, and nothing
  // re-encodes [A-Za-z0-9_-].
  function send(kind, message) {
    var encoded;
    try {
      encoded = btoa(unescape(encodeURIComponent(JSON.stringify(message))))
        .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    } catch (_) {
      return;
    }
    var id = page + "-" + seq++;
    var total = Math.max(1, Math.ceil(encoded.length / CHUNK));
    for (var i = 0; i < total; i++) {
      queue.push(PATH + kind + "?id=" + id + "&i=" + i + "&n=" + total + "&d=" + encoded.slice(i * CHUNK, (i + 1) * CHUNK));
    }
    pump();
  }

  function text(value) {
    try {
      if (value instanceof Error) return String(value.stack || value.message || value);
      if (typeof value === "object" && value !== null) return JSON.stringify(value).slice(0, 2000);
      return String(value);
    } catch (_) {
      return Object.prototype.toString.call(value);
    }
  }

  var pending = [];
  var flushing = null;
  function flush() {
    flushing = null;
    send("console", { page: page, href: location.href, lines: pending.splice(0, 200) });
    // More than one batch waiting: the rest goes next, not with the next console call (which may never come).
    if (pending.length) flushing = setTimeout(flush, 50);
  }
  function note(level, args) {
    pending.push({ t: Date.now(), level: level, text: Array.prototype.map.call(args, text).join(" ").slice(0, 4000) });
    if (!flushing) flushing = setTimeout(flush, 300);
  }

  ["log", "info", "warn", "error", "debug"].forEach(function (level) {
    var original = console[level];
    console[level] = function () {
      try {
        note(level, arguments);
      } catch (_) {}
      return original.apply(console, arguments);
    };
  });
  window.addEventListener(
    "error",
    function (event) {
      if (event.target && event.target !== window && event.target.src) {
        // A resource that failed to load (a script or stylesheet), not one of this probe's own requests.
        if (String(event.target.src).indexOf(PATH) < 0) note("resource-error", [event.target.tagName + " " + event.target.src]);
        return;
      }
      note("uncaught", [event.message + " @" + event.filename + ":" + event.lineno + ":" + event.colno, event.error || ""]);
    },
    true
  );
  window.addEventListener("unhandledrejection", function (event) {
    note("unhandledrejection", [event.reason]);
  });
  note("info", ["look probe loaded " + location.href]);

  // Boxes of the New Tab screen's parts and the stage under it: the first thing to read when a shot is blank.
  var SELECTORS = [".nt-screen", ".nt-composer", ".nt-field", ".acpmux-stage", "form.acpmux-composer", ".acpmux-main", "#root"];
  function box(selector) {
    var el = document.querySelector(selector);
    if (!el) return { selector: selector, found: false };
    var r = el.getBoundingClientRect();
    var cs = getComputedStyle(el);
    return {
      selector: selector,
      found: true,
      x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height),
      display: cs.display, visibility: cs.visibility, opacity: cs.opacity
    };
  }

  var last = "";
  function snapshot() {
    var root = document.getElementById("root") || document.body;
    var html = root ? root.outerHTML : "";
    var message = {
      page: page,
      href: location.href,
      title: document.title,
      // The page's own clock (the Mac's, as the shots' mtimes): a shot takes the snapshot taken last before it.
      t: Date.now(),
      // A hidden pane (a spare, another tab) sends snapshots too: a shot prefers the visible one.
      visibility: document.visibilityState,
      viewport: { w: innerWidth, h: innerHeight },
      newTabContext: window.__cmuxNewTabContext !== undefined,
      boxes: SELECTORS.map(box),
      text: ((document.body && document.body.innerText) || "").slice(0, 4000),
      html_length: html.length,
      html: html.slice(0, MAX_HTML)
    };
    var key = JSON.stringify([message.boxes, message.text, message.html, message.viewport, message.newTabContext,
      message.visibility]);
    if (key === last) return;
    // A page that changes faster than its snapshots go out sends the next one once the queue drains, not a backlog.
    if (queue.length > 300) return;
    last = key;
    send("dom", message);
  }
  // On every DOM change (200 ms after the last), so the snapshot of what a shot shows is taken before the shot,
  // which waits for the window to hold still; and once a second for what changes no node (layout, a resize).
  var soon = null;
  function changed(records) {
    // The probe's own <script> requests come and go in <head>: not a change of the page.
    if (records && records.every && records.every(function (r) { return r.target === document.head; })) return;
    if (soon) clearTimeout(soon);
    soon = setTimeout(function () {
      soon = null;
      snapshot();
    }, 200);
  }
  new MutationObserver(changed).observe(document.documentElement, {
    subtree: true, childList: true, attributes: true, characterData: true
  });
  document.addEventListener("visibilitychange", function () { changed(); });
  setInterval(snapshot, 1000);
  addEventListener("load", snapshot);
})();
