// Reference browser host: the domain policy, the secret vault, TOTP, output
// masking and capture masking, outside the agent's JS context, exactly where
// the Rust `cmux browser host` sits (plans/cmux-next/browser-host.md,
// section 4). It wraps a driver (the dev driver here) and the native host the
// runtime gets, so the conformance suite checks the runtime against the same
// contract the Rust host implements. Contract
// (2026-10-01):
//
// - natives (main's ABI, port plan D1): secrets(op, args) with set, load
//   {object}, list, has, delete, clear (agent-known values only), and
//   policy(op, args) with get, check {url}, site {host}, log and set
//   {allowed?, prohibited?, blockIPs?, lock?, title} (narrow only).
// - effective policy = base (user) intersected with the session layer (agent).
// - secret handles {__secret: name} resolve only in input.insertText.text,
//   input.key.text and the page agent's fill (frame.evaluate world "agent",
//   method "fill", value argument). The host never hands a value to page JS:
//   it focuses the element through the agent, finds the focused frame and
//   checks it is editable with its own code in the host world, takes that
//   frame's URL from frames.list (engine truth), checks it against the
//   secret's domains (https only, http on loopback, root covers www), and types
//   with native input.insertText, re-checking focus before each key.
// - frame.evaluate world "host" is a content world only the host uses (no
//   page agent, its own pristine prototypes on real engines); calls from the
//   agent context that name it are refused. Capture masking runs there too.
// - every byte leaving the host is masked: print, errors, driver results
//   (not captures), event payloads, fetch bodies, fs writes.
import crypto from "node:crypto";

const LOOPBACK = /^(localhost|127(?:\.\d{1,3}){3}|\[::1\])$/;
const isIPHost = (host) => /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || /^\[[0-9a-f:.]+\]$/i.test(host);
const htmlEscape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const TITLES = { "tab.navigate": "page.goto", "tabs.open": "tabs.open" };
const GUARDED = /^(frame\.evaluate|input\.|tab\.screenshot|tab\.pdf|clipboard\.|filechooser\.respond)/;
const NAVIGATIONS = new Set(["tab.navigate", "tab.history", "tab.reload"]);
const BINARY = new Set(["tab.screenshot", "tab.pdf", "clipboard.read"]);
const CAPTURES = new Set(["tab.screenshot", "tab.pdf"]);
const AGENT_DISPATCH = '(m, ...a) => globalThis[Symbol.for("cmux.browserRepl.agent")][m](...a)';

// Host-world page code: self-contained, never the page agent's.
const HOST_FOCUS = `() => {
  let a = document.activeElement;
  while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
  if (a === document.body || a === document.documentElement) a = null;
  const tag = a ? a.tagName : "";
  const textInput = a instanceof HTMLInputElement && !["button", "submit", "reset", "checkbox", "radio", "file", "image", "range", "color", "hidden"].includes(a.type);
  return { activeIsFrame: tag === "IFRAME" || tag === "FRAME", activeEditable: !!a && (textInput || a instanceof HTMLTextAreaElement || a.isContentEditable) };
}`;
const HOST_SELECT_ALL = `() => {
  let a = document.activeElement;
  while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
  if (a instanceof HTMLInputElement || a instanceof HTMLTextAreaElement) { a.select(); return true; }
  if (a && a.isContentEditable) { const r = document.createRange(); r.selectNodeContents(a); const s = getSelection(); s.removeAllRanges(); s.addRange(r); return true; }
  return false;
}`;
// After a capture: every element the mask covered still has it (a page that
// drops the mask during the capture makes the capture refused).
const HOST_MASK_HELD = `() => {
  const saved = globalThis[Symbol.for("cmux.browserHost.secretMask")] || [];
  return saved.every(([el]) => !el.isConnected || el.style.getPropertyValue("-webkit-text-security") === "disc");
}`;

const HOST_MASK = `(values, on) => {
  const key = Symbol.for("cmux.browserHost.secretMask");
  const prop = "-webkit-text-security";
  if (!on) {
    for (const [el, value, priority] of globalThis[key] || []) {
      if (value) el.style.setProperty(prop, value, priority);
      else el.style.removeProperty(prop);
    }
    globalThis[key] = null;
    return 0;
  }
  const hits = new Set();
  const has = (text) => typeof text === "string" && values.some((v) => text.includes(v));
  const visit = (root) => {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let n = walker.currentNode; n; n = walker.nextNode()) {
      if (n.nodeType === 3) { if (n.parentElement && has(n.data)) hits.add(n.parentElement); continue; }
      if ((n instanceof HTMLInputElement && n.type !== "password") || n instanceof HTMLTextAreaElement) { if (has(n.value)) hits.add(n); }
      if (n.shadowRoot) visit(n.shadowRoot);
    }
  };
  visit(document.documentElement || document);
  const saved = [];
  for (const el of hits) { saved.push([el, el.style.getPropertyValue(prop), el.style.getPropertyPriority(prop)]); el.style.setProperty(prop, "disc", "important"); }
  globalThis[key] = saved;
  return saved.length;
}`;

// ---- TOTP (RFC 6238, HMAC-SHA1) ------------------------------------------------

export function base32Decode(s) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const clean = String(s).toUpperCase().replace(/[\s=-]/g, "");
  const out = [];
  let bits = 0;
  let value = 0;
  for (const c of clean) {
    const i = alphabet.indexOf(c);
    if (i < 0) throw new Error("secrets: a TOTP secret must be base32");
    value = (value << 5) | i;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

export function totp(secretBase32, timeMs, { digits = 6, period = 30 } = {}) {
  const counter = Math.floor(timeMs / 1000 / period);
  const msg = Buffer.alloc(8);
  msg.writeUInt32BE(Math.floor(counter / 2 ** 32), 0);
  msg.writeUInt32BE(counter >>> 0, 4);
  const h = crypto.createHmac("sha1", base32Decode(secretBase32)).update(msg).digest();
  const o = h[19] & 15;
  const code = (((h[o] & 127) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3]) % 10 ** digits;
  return String(code).padStart(digits, "0");
}

// ---- WebKit content rules for a policy -------------------------------------------
// Content-blocker regular expressions have no alternation, so each pattern
// becomes its own rule. Documents are blocked in every frame (no
// load-context), so an off-policy main-frame navigation never sends its
// request; the driver reports it as navigation.blocked.

const SUBRESOURCES = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping", "fetch", "websocket", "other"];
const cbEscape = (s) => s.replace(/[.+?^${}()|[\]\\*]/g, "\\$&");
function patternFilters(p) {
  const schemes = p.scheme ? [p.scheme.split("").map((c) => (c === "*" ? "[a-z0-9+.-]*" : cbEscape(c))).join("")] : ["https?", "wss?"];
  return schemes.flatMap((scheme) => schemeFilters(p, scheme));
}
function schemeFilters(p, scheme) {
  let host;
  if (p.host === "*") host = "[^/@:]+";
  else if (p.host.startsWith("*.")) host = "([^/@:]*\\.)?" + cbEscape(p.host.slice(2));
  else host = cbEscape(p.host);
  const head = "^" + scheme + "://([^/@]*@)?" + host;
  if (p.port === null) return [head + "(:[0-9]+)?/"];
  const out = [head + ":" + p.port + "/"];
  if ((p.port === "443" && (!p.scheme || /^https/.test(p.scheme) || p.scheme === "*")) || (p.port === "80" && (!p.scheme || /^http/.test(p.scheme) || p.scheme === "*"))) out.push(head + "/");
  return out;
}
export function policyContentRules({ allowLists, prohibited, blockIPs }) {
  const rules = [];
  const add = (filter, type) => {
    rules.push({ trigger: { "url-filter": filter, "resource-type": SUBRESOURCES }, action: { type } });
    rules.push({ trigger: { "url-filter": filter, "resource-type": ["document"] }, action: { type } });
  };
  // Content rules cannot express an intersection, so the allow list is the
  // pairwise intersection of the user's and the agent's lists.
  const allowed = intersectAllowLists(allowLists);
  if (allowed) {
    add(".*", "block");
    for (const p of allowed) for (const f of patternFilters(p)) add(f, "ignore-previous-rules");
    for (const scheme of ["data", "blob", "about"]) add("^" + scheme + ":", "ignore-previous-rules");
  }
  for (const p of prohibited) for (const f of patternFilters(p)) add(f, "block");
  if (blockIPs) {
    add("^[a-z][a-z0-9+.-]*://([^/@]*@)?[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+[:/]", "block");
    add("^[a-z][a-z0-9+.-]*://([^/@]*@)?\\[", "block");
  }
  return rules;
}

// ---- pattern intersection ---------------------------------------------------------------
// The URLs both patterns allow, as one pattern, or null. A pattern covers
// another when every URL the second allows, the first allows too.
const hostCovers = (a, b) => a === "*" || a === b || (a.startsWith("*.") && (b === a.slice(2) || b.endsWith(a.slice(1))));
const schemeCovers = (a, b) => a === null ? b === null || /^(https?|wss?|http\*)$/.test(b) : a === "*" || a === b || (a === "http*" && /^https?$/.test(b || ""));
function covers(a, b) {
  return hostCovers(a.host, b.host) && schemeCovers(a.scheme, b.scheme) && (a.port === null || a.port === b.port);
}
export function intersectAllowLists(lists) {
  let out = null;
  for (const list of lists) {
    if (!out) {
      out = list;
      continue;
    }
    const next = [];
    for (const a of out) for (const b of list) {
      if (covers(a, b)) next.push(b);
      else if (covers(b, a)) next.push(a);
    }
    out = [...new Map(next.map((p) => [p.raw, p])).values()];
  }
  return out;
}

// ---- the host ------------------------------------------------------------------------

export function createReferenceHost(ns, { host, driver }) {
  const { parsePattern, urlMatches } = ns.agentTools;
  const now = () => (host.now ? host.now() : Date.now());

  // Vault. Values never cross into the agent context.
  const vault = new Map(); // name -> { value, domains: [pattern], totp, agentKnown }
  let masks = [];
  let rawCdp = false;
  function rebuildMasks() {
    const list = [];
    for (const [name, s] of vault) {
      const mask = `<secret:${name}>`;
      const variants = new Set([s.value, encodeURIComponent(s.value), encodeURIComponent(s.value).replace(/%20/g, "+"), new URLSearchParams({ v: s.value }).toString().slice(2), JSON.stringify(s.value).slice(1, -1), htmlEscape(s.value)]);
      for (const v of variants) if (v) list.push([v, mask]);
    }
    masks = list.sort((a, b) => b[0].length - a[0].length);
  }
  // The codes of every TOTP secret a server still accepts (one window on
  // each side of the current one), as whole numbers only.
  const totpCodes = () => {
    const out = [];
    const t = now();
    for (const [name, s] of vault) {
      if (!s.totp) continue;
      for (const at of [t - 30_000, t, t + 30_000]) out.push([totp(s.value, at), `<secret:${name}>`]);
    }
    return out;
  };
  const maskText = (text) => {
    if (!masks.length || typeof text !== "string") return text;
    for (const [v, mask] of masks) if (text.includes(v)) text = text.split(v).join(mask);
    for (const [code, mask] of totpCodes()) text = text.replace(new RegExp(`(?<!\\d)${code}(?!\\d)`, "g"), mask);
    return text;
  };
  function maskValue(value, depth = 0) {
    if (!masks.length) return value;
    if (typeof value === "string") return maskText(value);
    if (!value || typeof value !== "object" || depth > 64) return value;
    if (Array.isArray(value)) return value.map((v) => maskValue(v, depth + 1));
    const out = {};
    for (const k of Object.keys(value)) out[k] = maskValue(value[k], depth + 1);
    return out;
  }
  function maskError(e) {
    if (masks.length && e && typeof e === "object") {
      for (const k of ["message", "stack"]) {
        try {
          if (typeof e[k] === "string") e[k] = maskText(e[k]);
        } catch {}
      }
    }
    return e;
  }
  // Text bodies are masked; bytes that are not valid UTF-8 pass unchanged.
  const strictUTF8 = new TextDecoder("utf-8", { fatal: true });
  // Bytes that are not valid UTF-8 are masked by each value's UTF-8 bytes.
  const maskBytes = (bytes) => {
    let out = bytes;
    for (const [v, mask] of masks) {
      const needle = Buffer.from(v, "utf8");
      const parts = [];
      let from = 0;
      for (let at = out.indexOf(needle, from); at >= 0; at = out.indexOf(needle, from)) {
        parts.push(out.subarray(from, at), Buffer.from(mask, "utf8"));
        from = at + needle.length;
      }
      if (parts.length) out = Buffer.concat([...parts, out.subarray(from)]);
    }
    return out;
  };
  const maskBase64 = (b64) => {
    if (!masks.length || !b64) return b64;
    const bytes = Buffer.from(b64, "base64");
    let text;
    try {
      text = strictUTF8.decode(bytes);
    } catch {
      const masked = maskBytes(bytes);
      return masked === bytes ? b64 : masked.toString("base64");
    }
    const masked = maskText(text);
    return masked === text ? b64 : Buffer.from(masked, "utf8").toString("base64");
  };
  const describe = (name) => {
    const s = vault.get(name);
    return { name, domains: s.domains.map((d) => d.raw), totp: s.totp, agentKnown: s.agentKnown };
  };
  function putSecret(name, value, options, agentKnown, title) {
    if (typeof name !== "string" || !/^[\w.-]{1,64}$/.test(name)) throw new Error(`${title}: name: expected letters, digits, _, . or - (at most 64), got ${JSON.stringify(name)}`);
    if (typeof value !== "string" || !value) throw new Error(`${title}: ${name}: value: expected a non-empty string`);
    const domains = options && options.domains;
    if (!Array.isArray(domains) || !domains.length) throw new Error(`${title}: ${name}: domains: expected the domains it may be typed into, such as ["example.com"]; a secret without domains is not accepted`);
    const totpOn = !!(options.totp || /bu_2fa_code$/.test(name));
    if (totpOn) base32Decode(value);
    // An agent may not replace a secret the user gave the host.
    const prior = vault.get(name);
    if (prior && !prior.agentKnown && agentKnown) throw new Error(`${title}: ${name}: the user set this secret; choose another name`);
    vault.set(name, { value, domains: domains.map((d) => parsePattern(d, title)), totp: totpOn, agentKnown });
    rebuildMasks();
    return describe(name);
  }

  // Policy: the user's base layer and the agent's session layer.
  const blank = () => ({ allowed: null, prohibited: [], blockIPs: false, locked: false });
  let base = blank();
  const layer = blank();
  const log = [];
  const blocking = new Map(); // targetId -> promise of the about:blank navigation
  const navigating = new Map(); // targetId -> count of runtime navigations in flight
  let contentRules = [];
  const allowLists = () => [base.allowed, layer.allowed].filter(Boolean);
  const policyActive = () => !!(allowLists().length || base.prohibited.length || layer.prohibited.length || base.blockIPs || layer.blockIPs);
  function urlReason(url) {
    if (!policyActive()) return null;
    const s = String(url);
    if (/^(about:|data:|blob:)/i.test(s)) return null;
    let target = s;
    if (!/^[a-z][a-z0-9+.-]*:/i.test(target)) target = "https://" + target;
    let u;
    try {
      u = new URL(target);
    } catch {
      return "not a valid URL";
    }
    const h = String(u.hostname || "").toLowerCase();
    if (!h) return `its scheme ${u.protocol} has no host`;
    if ((base.blockIPs || layer.blockIPs) && isIPHost(h)) return "IP addresses are blocked (session.blockIPAddresses)";
    for (const list of allowLists()) if (!list.some((p) => urlMatches(target, p, false))) return `not in session.allowedDomains (${list.map((p) => p.raw).join(", ")})`;
    const hit = [...base.prohibited, ...layer.prohibited].find((p) => urlMatches(target, p, false));
    if (hit) return `prohibited by ${hit.raw} (session.prohibitedDomains)`;
    return null;
  }
  const lastBlock = new Map(); // targetId -> its last log entry
  const record = (url, reason, blocked, targetId) => {
    const entry = { url: String(url), reason, at: new Date(now()).toISOString(), blocked };
    log.push(entry);
    if (targetId) lastBlock.set(targetId, entry);
  };
  function checkURL(title, url) {
    const reason = urlReason(url);
    if (reason) {
      record(url, reason, "before");
      throw Object.assign(new Error(`${title}: ${url} is blocked: ${reason}`), { code: "forbidden" });
    }
  }
  function blockPage(targetId, url, reason) {
    if (blocking.has(targetId)) return blocking.get(targetId);
    record(url, reason, "after", targetId);
    const p = driver.call("tab.navigate", { targetId, url: "about:blank", waitUntil: "load", timeoutMs: 10000 })
      .catch(() => {})
      .finally(() => blocking.delete(targetId));
    blocking.set(targetId, p);
    return p;
  }
  // Cookie guards (main's BrowserReplDomainPolicy, merged from
  // native-boundary.mjs): hosts, not origins, so a pattern's scheme and port
  // do not narrow them; an allowed pattern covers a cookie its host receives.
  const T = ns.agentTools;
  const hostOnly = (p) => ({ ...p, scheme: null, port: null });
  const allowedEffective = () => intersectAllowLists(allowLists());
  const prohibitedAll = () => [...base.prohibited, ...layer.prohibited];
  function cookieBlockReason(domain) {
    if (!policyActive()) return null;
    const h = T.normalizeHost(String(domain || "").replace(/^\.+/, ""));
    if (!h) return "the cookie names no domain";
    if ((base.blockIPs || layer.blockIPs) && (isIPHost(h) || /(^|\.)(\d+|0x[0-9a-f]*)$/i.test(h))) return "IP addresses are blocked (session.blockIPAddresses)";
    const names = (p, name) => T.urlMatches(`http://${name}/`, hostOnly(p), false);
    const receives = (p) => names(p, h) || p.host === "*" || String(p.host).replace(/^\*\./, "").endsWith("." + h);
    const allowed = allowedEffective();
    if (allowed && !allowed.some(receives)) return `not in session.allowedDomains (${allowed.map((p) => p.raw).join(", ")})`;
    const hit = prohibitedAll().find((p) => names(p, h));
    return hit ? `prohibited by ${hit.raw} (session.prohibitedDomains)` : null;
  }
  // A cookie with a Domain attribute reaches every subdomain, so an allowed
  // pattern must cover all of them and no prohibited host may be among them.
  function cookieSetBlockReason(domain) {
    const first = cookieBlockReason(domain);
    if (first || !policyActive()) return first;
    const raw = String(domain || "").trim();
    const allowed = allowedEffective();
    if (!raw.startsWith(".")) {
      const h = T.normalizeHost(raw);
      if (allowed && !allowed.some((p) => T.urlMatches(`http://${h}/`, hostOnly(p), false))) return `not in session.allowedDomains (${allowed.map((p) => p.raw).join(", ")})`;
      return null;
    }
    const h = T.normalizeHost(raw.replace(/^\.+/, ""));
    const covers = (p) => p.host === "*" || (p.host.startsWith("*.") && (h === p.host.slice(2) || h.endsWith("." + p.host.slice(2))));
    if (allowed && !allowed.some(covers)) return `a cookie on ${h} reaches its other subdomains, which session.allowedDomains (${allowed.map((p) => p.raw).join(", ")}) does not all allow; set it on the allowed host itself`;
    const under = (p) => {
      if (p.host === "*") return true;
      const named = String(p.host).replace(/^\*\./, "");
      return named === h || named.endsWith("." + h) || h.endsWith("." + named);
    };
    const hit = prohibitedAll().find(under);
    return hit ? `a cookie on ${h} reaches ${hit.raw} (session.prohibitedDomains)` : null;
  }
  async function syncContentRules() {
    contentRules = policyContentRules({ allowLists: allowLists(), prohibited: [...base.prohibited, ...layer.prohibited], blockIPs: base.blockIPs || layer.blockIPs });
    // The dev driver takes the whole policy, as main's driver does: cookie
    // guards, refusals on tabs that show a blocked page, and the content
    // rules (it refuses every call while WebKit could not compile them).
    if (typeof driver.setDomainPolicy === "function") {
      const policy = { allowed: allowedEffective(), prohibited: prohibitedAll(), blockIPs: base.blockIPs || layer.blockIPs };
      await driver.setDomainPolicy(policy, urlReason, cookieBlockReason, cookieSetBlockReason, contentRules);
      return;
    }
    try {
      await driver.call("session.configure", { contentRules });
    } catch (e) {
      if (!(e && e.code === "unsupported")) host.print("warn", `# subresource blocking is off: ${(e && e.message) || e}`);
    }
  }
  const flatPolicy = () => {
    const allowed = intersectAllowLists(allowLists());
    return {
      allowed: allowed ? allowed.map((p) => p.raw) : null,
      prohibited: [...base.prohibited, ...layer.prohibited].map((p) => p.raw),
      blockIPs: base.blockIPs || layer.blockIPs,
      locked: base.locked || layer.locked,
    };
  };
  let rulesSync = Promise.resolve();
  function narrow(change) {
    const title = change.title || "session.policy";
    if (base.locked || layer.locked) throw new Error(`${title}: the domain policy is locked for this session`);
    // Parse everything before changing anything.
    const allowed = "allowed" in change ? (change.allowed && change.allowed.length ? change.allowed.map((d) => parsePattern(d, "policy")) : null) : layer.allowed;
    const prohibited = "prohibited" in change ? (change.prohibited || []).map((d) => parsePattern(d, "policy")) : layer.prohibited;
    Object.assign(layer, { allowed, prohibited });
    if ("blockIPs" in change) layer.blockIPs = !!change.blockIPs;
    if (change.lock) layer.locked = true;
    rulesSync = syncContentRules();
    return flatPolicy();
  }

  // Watch the engine directly: enforcement does not depend on the runtime.
  driver.on("tab.navigated", async (p) => {
    if (!policyActive() || !p || !p.url || navigating.has(p.targetId)) return;
    const reason = urlReason(p.url);
    if (!reason) return;
    const frames = await driver.call("frames.list", { targetId: p.targetId }).catch(() => []);
    const main = frames.find((f) => !f.parentFrameId);
    if (main && main.frameId !== p.frameId) return;
    host.print("warn", maskText(`# navigation to ${p.url} was blocked: ${reason}; the tab now shows about:blank`));
    blockPage(p.targetId, p.url, reason);
  });
  driver.on("navigation.blocked", (p) => {
    const reason = p && p.url && urlReason(p.url);
    if (reason) record(p.url, reason, "before", p.targetId);
  });
  driver.on("tab.created", (p) => {
    const reason = p && p.url && urlReason(p.url);
    if (!reason) return;
    record(p.url, reason, "popup");
    host.print("warn", maskText(`# a new tab for ${p.url} was closed: ${reason}`));
    driver.call("tabs.close", { targetId: p.targetId }).catch(() => {});
  });

  // Secret handles.
  const isHandle = (v) => v !== null && typeof v === "object" && !Array.isArray(v) && typeof v.__secret === "string" && Object.keys(v).length === 1;
  const containsHandle = (v, depth = 0) => {
    if (isHandle(v)) return true;
    if (!v || typeof v !== "object" || depth > 16) return false;
    return Object.values(v).some((x) => containsHandle(x, depth + 1));
  };
  const hostEval = (targetId, frameId, source, args = []) => driver.call("frame.evaluate", { targetId, frameId, world: "host", source, args, awaitPromise: true });
  // The frame that holds focus, by the host's own code: descend from the
  // main frame while focus is on a frame element, into the single child
  // frame with focus inside. URLs come from frames.list, never from page JS.
  async function focusedFrame(targetId) {
    const frames = await driver.call("frames.list", { targetId });
    let frame = frames.find((f) => !f.parentFrameId);
    let state = await hostEval(targetId, frame.frameId, HOST_FOCUS);
    while (state.activeIsFrame) {
      const candidates = [];
      for (const child of frames.filter((f) => f.parentFrameId === frame.frameId)) {
        const s = await hostEval(targetId, child.frameId, HOST_FOCUS).catch(() => null);
        if (s && (s.activeEditable || s.activeIsFrame)) candidates.push([child, s]);
      }
      if (candidates.length !== 1) throw new Error("focus is ambiguous");
      [frame, state] = candidates[0];
    }
    return { frame, editable: state.activeEditable };
  }
  function secretValue(h, url, title) {
    const entry = vault.get(h.__secret);
    if (!entry) throw new Error(`${title}: secret ${JSON.stringify(h.__secret)} was deleted`);
    if (rawCdp) throw new Error(`${title}: secret ${JSON.stringify(h.__secret)} cannot be typed in a session with raw CDP access`);
    if (!entry.domains.some((d) => urlMatches(url, d, true))) {
      throw new Error(`${title}: secret ${JSON.stringify(h.__secret)} may not be typed into ${String(url).replace(/[?#].*$/, "")}; its domains are ${entry.domains.map((d) => d.raw).join(", ")}`);
    }
    return entry.totp ? totp(entry.value, now()) : entry.value;
  }
  // Checks where focus is and returns the value for that frame.
  async function checkedValue(targetId, h, title, expectFrameId) {
    const { frame, editable } = await focusedFrame(targetId);
    if (expectFrameId && frame.frameId !== expectFrameId) throw new Error(`${title}: secret ${JSON.stringify(h.__secret)}: focus left the element`);
    if (!editable) throw new Error(`${title}: secret ${JSON.stringify(h.__secret)} can only be typed into a text field`);
    return { value: secretValue(h, frame.url, title), frame };
  }
  // Types `value` with native input into the checked frame; for keys, focus
  // is checked again before each character.
  async function typeSecret(targetId, h, title, { keys, delayMs, frameId }) {
    const first = await checkedValue(targetId, h, title, frameId);
    if (!keys) return driver.call("input.insertText", { targetId, text: first.value });
    let index = 0;
    for (const ch of first.value) {
      if (index++) await checkedValue(targetId, h, title, first.frame.frameId);
      if (ns.core.KEYS[ch]) {
        const desc = ns.core.describeKey(ch, new Set());
        for (const type of ["down", "up"]) await driver.call("input.key", { targetId, type, key: desc.key, code: desc.code, text: type === "down" ? desc.text || undefined : undefined, location: desc.location, modifiers: [] });
      } else await driver.call("input.insertText", { targetId, text: ch });
      if (delayMs > 0) await new Promise((r) => setTimeout(r, delayMs));
    }
    return null;
  }
  const titleOf = (params, fallback) => (typeof params.title === "string" && /^locator\.\w+$/.test(params.title) ? params.title : fallback);
  // Runs one call that carries a secret handle, or refuses it.
  async function secretCall(method, params) {
    if (method === "frame.evaluate" && params.world === "agent" && params.source === AGENT_DISPATCH && params.args && params.args[0] === "fill" && isHandle(params.args[2]) && !containsHandle(params.args.slice(0, 2)) && !containsHandle(params.args.slice(3))) {
      const h = params.args[2];
      const frames = await driver.call("frames.list", { targetId: params.targetId });
      const frameId = params.frameId || frames.find((f) => !f.parentFrameId).frameId;
      const focused = await driver.call("frame.evaluate", { targetId: params.targetId, frameId: params.frameId, world: "agent", source: AGENT_DISPATCH, args: ["focus", params.args[1], true], awaitPromise: true });
      if (focused === "error:notconnected") return focused;
      await checkedValue(params.targetId, h, "locator.fill", frameId);
      await hostEval(params.targetId, frameId, HOST_SELECT_ALL);
      await typeSecret(params.targetId, h, "locator.fill", { keys: false, frameId });
      return "done";
    }
    if ((method === "input.insertText" || method === "input.key") && isHandle(params.text) && !containsHandle({ ...params, text: null })) {
      const keys = method === "input.insertText" && params.typing === "keys";
      return typeSecret(params.targetId, params.text, titleOf(params, keys ? "locator.type" : "locator.fill"), { keys, delayMs: Number(params.delayMs) || 0 });
    }
    throw Object.assign(new Error(`${method}: a secret handle is accepted only as the text of typed input or the value of locator.fill`), { code: "forbidden" });
  }

  // User secrets go only to frames on their domains; agent-known ones to
  // every frame. Captures of one tab run one at a time.
  async function maskCaptures(targetId, on) {
    const frames = await driver.call("frames.list", { targetId }).catch(() => []);
    for (const f of frames) {
      const values = [...vault.values()].filter((s) => !s.totp && s.value && (s.agentKnown || s.domains.some((d) => urlMatches(f.url, d, true)))).map((s) => s.value);
      if (!values.length && on) continue;
      await hostEval(targetId, f.frameId, HOST_MASK, [values, on]).catch(() => {});
    }
  }
  const captureChains = new Map();
  function serialCapture(targetId, run) {
    const prior = captureChains.get(targetId) || Promise.resolve();
    const next = prior.catch(() => {}).then(run);
    captureChains.set(targetId, next.catch(() => {}));
    return next;
  }

  const vmCalls = [];
  async function hostedCall(method, params = {}) {
    vmCalls.push({ method, params: JSON.parse(JSON.stringify(params)) });
    try {
      await rulesSync;
      if (method === "frame.evaluate" && params.world === "host") throw Object.assign(new Error("frame.evaluate: the host world is the host's"), { code: "forbidden" });
      if (method === "session.configure" && params) {
        const { contentRules: _ignored, ...rest } = params;
        params = rest;
        if (policyActive() && params.proxy) throw Object.assign(new Error("session.configure: a proxy cannot be set while a domain policy is active"), { code: "forbidden" });
      }
      if ((method === "tab.navigate" || method === "tabs.open") && params.url) checkURL(TITLES[method], params.url);
      if (policyActive() && params.targetId && GUARDED.test(method)) {
        const pending = blocking.get(params.targetId);
        if (pending) await pending;
        const info = await driver.call("tab.info", { targetId: params.targetId }).catch(() => null);
        const reason = info && info.url && urlReason(info.url);
        if (reason) {
          await blockPage(params.targetId, info.url, reason);
          throw new Error(`${method === "frame.evaluate" ? "page" : method}: navigation to ${info.url} was blocked: ${reason}; the tab now shows about:blank`);
        }
      }
      if (containsHandle(params)) return maskValue(await secretCall(method, params));
      if (CAPTURES.has(method) && params.targetId) {
        return await serialCapture(params.targetId, async () => {
          await maskCaptures(params.targetId, true);
          try {
            const shot = await driver.call(method, params);
            const frames = await driver.call("frames.list", { targetId: params.targetId }).catch(() => []);
            for (const f of frames) {
              const held = await hostEval(params.targetId, f.frameId, HOST_MASK_HELD, []).catch(() => true);
              if (held === false) throw Object.assign(new Error(`${method}: the page removed the secret mask during the capture; the capture is refused`), { code: "invalid" });
            }
            return shot;
          } finally {
            await maskCaptures(params.targetId, false);
          }
        });
      }
      return await navigationCall(method, params);
    } catch (e) {
      throw maskError(e);
    }
  }

  async function navigationCall(method, params) {
    const nav = NAVIGATIONS.has(method) && params.targetId;
    if (nav) navigating.set(params.targetId, (navigating.get(params.targetId) || 0) + 1);
    try {
      const r = await driver.call(method, params);
      if (policyActive() && nav && r && r.url && params.url !== "about:blank") {
        const reason = urlReason(r.url);
        if (reason) {
          await blockPage(params.targetId, r.url, reason);
          throw new Error(`${TITLES[method] || method}: navigation to ${r.url} was blocked: ${reason}; the tab now shows about:blank`);
        }
      }
      return BINARY.has(method) ? r : maskValue(r);
    } finally {
      if (nav) {
        const n = (navigating.get(params.targetId) || 1) - 1;
        if (n) navigating.set(params.targetId, n);
        else navigating.delete(params.targetId);
        // A navigation that failed or was replaced may have left the tab
        // anywhere; check it, since its own events were not watched.
        if (policyActive() && !blocking.has(params.targetId)) {
          const info = await driver.call("tab.info", { targetId: params.targetId }).catch(() => null);
          const reason = info && info.url && urlReason(info.url);
          if (reason) blockPage(params.targetId, info.url, reason);
        }
      }
    }
  }

  // Plain objects with no prototype: nothing reaches the raw driver or host.
  const hostedDriver = Object.assign(Object.create(null), {
    name: driver.name,
    call: hostedCall,
    on: (event, handler) => driver.on(event, (payload) => handler(maskValue(payload))),
    capabilities: () => (driver.capabilities ? driver.capabilities() : []),
    detach: () => (driver.detach ? driver.detach() : undefined),
  });

  const hostedHost = Object.create(null);
  Object.defineProperties(hostedHost, Object.getOwnPropertyDescriptors(host));
  Object.assign(hostedHost, {
    print: (level, text) => host.print(level, maskText(text)),
    console: { error: (text) => (host.console ? host.console.error(maskText(text)) : host.print("error", maskText(text))) },
    fsOp: (op, args) => {
      if (op === "writeFile" && args && args.base64) args = { ...args, base64: maskBase64(args.base64) };
      const r = host.fsOp(op, args);
      return op === "readFile" ? maskBase64(r) : maskValue(r);
    },
    // Redirects are followed here, one hop at a time, each checked.
    fetch: async (url, init = {}) => {
      let current = url;
      let request = { ...init };
      for (let hop = 0; hop <= 20; hop++) {
        checkURL("fetch", current);
        const r = await host.fetch(current, { ...request, redirect: "manual" });
        const location = r.headers && (r.headers.location || r.headers.Location);
        if ([301, 302, 303, 307, 308].includes(r.status) && location) {
          current = new URL(location, current).href;
          if (r.status === 303 || ((r.status === 301 || r.status === 302) && request.method && request.method !== "GET" && request.method !== "HEAD")) request = { ...request, method: "GET", body: undefined };
          continue;
        }
        // A native fetch that cannot stop at redirects still has its final
        // URL checked before the body reaches the agent.
        if (r.url && r.url !== current) checkURL("fetch", r.url);
        return { ...r, url: r.url || current, redirected: hop > 0 || !!r.redirected, base64: maskBase64(r.base64) };
      }
      throw new Error(`fetch: ${url}: too many redirects`);
    },
    secrets(op, args = {}) {
      switch (op) {
        case "set":
          putSecret(args.name, args.value, { domains: args.domains, totp: args.totp }, true, "secrets.set");
          return { name: args.name, domains: args.domains, totp: !!vault.get(args.name).totp };
        case "load": {
          // A path is read here, through the session's fs, as the Rust host
          // reads it through its sandbox: the values never enter the VM.
          let object = args.object;
          if (typeof args.path === "string") {
            const text = Buffer.from(host.fsOp("readFile", { path: args.path }), "base64").toString("utf8");
            try {
              object = JSON.parse(text);
            } catch {
              throw new Error(`secrets.load: ${args.path} is not JSON`);
            }
          }
          const merged = new Map();
          for (const [pattern, entries] of Object.entries(object || {})) {
            for (const [name, v] of Object.entries(entries || {})) {
              const value = v && typeof v === "object" ? v.value : v;
              const totp = !!(v && typeof v === "object" && v.totp);
              const prior = merged.get(name);
              if (prior && prior.value === value) {
                prior.domains.push(pattern);
                prior.totp = prior.totp || totp;
              } else merged.set(name, { value, domains: [pattern], totp });
            }
          }
          return [...merged].map(([name, m]) => {
            putSecret(name, m.value, { domains: m.domains, totp: m.totp }, true, "secrets.load");
            return { name, domains: m.domains, totp: !!vault.get(name).totp };
          });
        }
        case "list":
          return [...vault.keys()].map(describe);
        case "has":
          return vault.has(args.name);
        case "delete": {
          const s = vault.get(args.name);
          if (s && !s.agentKnown) throw new Error(`secrets.delete: ${args.name} is a user secret; agent code cannot change it`);
          const had = vault.delete(args.name);
          rebuildMasks();
          return had;
        }
        case "clear":
          for (const [name, s] of [...vault]) if (s.agentKnown) vault.delete(name);
          rebuildMasks();
          return null;
        default:
          throw new Error(`secrets: unknown operation ${JSON.stringify(op)}`);
      }
    },
    policy(op, args = {}) {
      switch (op) {
        case "get":
          return flatPolicy();
        case "check":
          return urlReason(args.url);
        case "site":
          return ns.agentTools.registrableDomain(String(args.host || ""));
        case "log":
          return log.map((e) => maskValue({ ...e }));
        case "set":
          return narrow(args);
        default:
          throw new Error(`policy: unknown operation ${JSON.stringify(op)}`);
      }
    },
  });

  return {
    host: hostedHost,
    driver: hostedDriver,
    maskText,
    maskError,
    // Host operations with origin "user" (browser.secrets.load, policy.set).
    loadUserSecret: (name, value, options) => putSecret(name, value, options, false, "browser.secrets.load"),
    setBasePolicy(policy) {
      const next = blank();
      if (policy.allowed) next.allowed = policy.allowed.map((d) => parsePattern(d, "browser.policy.set"));
      if (policy.prohibited) next.prohibited = policy.prohibited.map((d) => parsePattern(d, "browser.policy.set"));
      next.blockIPs = !!policy.blockIPAddresses;
      next.locked = !!policy.lock;
      base = next;
      rulesSync = syncContentRules();
      return rulesSync;
    },
    grantRawCdp: () => {
      rawCdp = true;
    },
    contentRules: () => contentRules,
    vmDriverCalls: () => vmCalls,
  };
}
