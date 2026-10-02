// Reference browser host: the domain policy, the secret vault, TOTP, output
// masking and capture masking, outside the agent's JS context, exactly where
// the Rust `cmux browser host` sits (plans/cmux-next/browser-host.md,
// section 4). It wraps a driver (the dev driver here) and the native host the
// runtime gets, so the conformance suite checks the runtime against the same
// contract the Rust host implements. Contract, agreed with the browser-use
// lead (2026-10-01):
//
// - natives: secretSet(name, value, {domains, totp}) (agent-known),
//   secretList(), secretDelete(name), policyNarrow({allowed?, prohibited?,
//   blockIPAddresses?, lock?}), policyGet(), policyLog(), policyCheck(targetId).
// - effective policy = base (user) intersected with the session layer (agent).
// - secret handles {__secret: name} resolve only in input.insertText.text,
//   input.key.text and the page agent's fill (frame.evaluate world "agent",
//   method "fill", value argument), after the receiving frame's URL matches the
//   secret's domains (https only, http on loopback, root covers www).
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
const agentSource = (method) => `(...a) => globalThis[Symbol.for("cmux.browserRepl.agent")].${method}(...a)`;

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
// becomes its own rule. Main-frame documents are left to the navigation
// checks, which report the block; iframes and subresources are blocked here.

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
    rules.push({ trigger: { "url-filter": filter, "resource-type": ["document"], "load-context": ["child-frame"] }, action: { type } });
  };
  // Content rules cannot intersect allow lists; the narrowest (last) one
  // blocks subresources, the navigation checks enforce all of them.
  const allowed = allowLists.at(-1);
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
      const variants = new Set([s.value, encodeURIComponent(s.value), encodeURIComponent(s.value).replace(/%20/g, "+"), JSON.stringify(s.value).slice(1, -1), htmlEscape(s.value)]);
      for (const v of variants) if (v) list.push([v, mask]);
    }
    masks = list.sort((a, b) => b[0].length - a[0].length);
  }
  const maskText = (text) => {
    if (!masks.length || typeof text !== "string") return text;
    for (const [v, mask] of masks) if (text.includes(v)) text = text.split(v).join(mask);
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
  // Text bodies are masked; bytes that are not text pass unchanged.
  const maskBase64 = (b64) => {
    if (!masks.length || !b64) return b64;
    const text = Buffer.from(b64, "base64").toString("utf8");
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
  const record = (url, reason, blocked) => log.push({ url: String(url), reason, at: new Date(now()).toISOString(), blocked });
  function checkURL(title, url) {
    const reason = urlReason(url);
    if (reason) {
      record(url, reason, "before");
      throw Object.assign(new Error(`${title}: ${url} is blocked: ${reason}`), { code: "forbidden" });
    }
  }
  function blockPage(targetId, url, reason) {
    if (blocking.has(targetId)) return blocking.get(targetId);
    record(url, reason, "after");
    const p = driver.call("tab.navigate", { targetId, url: "about:blank", waitUntil: "load", timeoutMs: 10000 })
      .catch(() => {})
      .finally(() => blocking.delete(targetId));
    blocking.set(targetId, p);
    return p;
  }
  async function syncContentRules() {
    contentRules = policyContentRules({ allowLists: allowLists(), prohibited: [...base.prohibited, ...layer.prohibited], blockIPs: base.blockIPs || layer.blockIPs });
    try {
      await driver.call("session.configure", { contentRules });
    } catch (e) {
      if (!(e && e.code === "unsupported")) host.print("warn", `# subresource blocking is off: ${(e && e.message) || e}`);
    }
  }
  const flatPolicy = () => {
    const allowed = layer.allowed || base.allowed;
    return {
      allowed: allowed ? allowed.map((p) => p.raw) : null,
      prohibited: [...base.prohibited, ...layer.prohibited].map((p) => p.raw),
      blockIPAddresses: base.blockIPs || layer.blockIPs,
      locked: base.locked || layer.locked,
    };
  };
  let rulesSync = Promise.resolve();
  function narrow(change) {
    if (base.locked || layer.locked) throw new Error("the domain policy is locked for this session");
    if ("allowed" in change) layer.allowed = change.allowed && change.allowed.length ? change.allowed.map((d) => parsePattern(d, "policy")) : null;
    if ("prohibited" in change) layer.prohibited = (change.prohibited || []).map((d) => parsePattern(d, "policy"));
    if ("blockIPAddresses" in change) layer.blockIPs = !!change.blockIPAddresses;
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
  async function frameURL(targetId, frameId) {
    const frames = await driver.call("frames.list", { targetId });
    const f = frameId ? frames.find((x) => x.frameId === frameId) : frames.find((x) => !x.parentFrameId);
    if (!f) throw new Error("the frame is gone");
    return f.url;
  }
  // The frame that holds focus: descend from the main frame while focus is
  // on a frame element, into the single child frame that has focus inside.
  async function focusedFrameURL(targetId) {
    const frames = await driver.call("frames.list", { targetId });
    const info = (f) => driver.call("frame.evaluate", { targetId, frameId: f.frameId, world: "agent", source: agentSource("focusInfo"), args: [], awaitPromise: true });
    let frame = frames.find((f) => !f.parentFrameId);
    let state = await info(frame);
    while (state.activeIsFrame) {
      const children = frames.filter((f) => f.parentFrameId === frame.frameId);
      const candidates = [];
      for (const child of children) {
        const s = await info(child).catch(() => null);
        if (s && (s.activeEditable || s.activeIsFrame)) candidates.push([child, s]);
      }
      if (candidates.length !== 1) throw new Error("focus is ambiguous");
      [frame, state] = candidates[0];
    }
    return state.url;
  }
  async function resolveHandle(h, url, title) {
    const entry = vault.get(h.__secret);
    if (!entry) throw new Error(`${title}: secret ${JSON.stringify(h.__secret)} was deleted`);
    if (rawCdp) throw new Error(`${title}: secret ${JSON.stringify(h.__secret)} cannot be typed in a session with raw CDP access`);
    if (!entry.domains.some((d) => urlMatches(url, d, true))) {
      throw new Error(`${title}: secret ${JSON.stringify(h.__secret)} may not be typed into ${String(url).replace(/[?#].*$/, "")}; its domains are ${entry.domains.map((d) => d.raw).join(", ")}`);
    }
    return entry.totp ? totp(entry.value, now()) : entry.value;
  }
  // Resolves the handles of one call or refuses it. Returns the calls to send
  // (a keyed insert expands into the runtime's own per-character sequence).
  async function resolveCall(method, params) {
    if (!containsHandle(params)) return [[method, params]];
    if (method === "frame.evaluate" && params.world === "agent" && params.source === AGENT_DISPATCH && params.args && params.args[0] === "fill" && isHandle(params.args[2]) && !containsHandle(params.args.slice(0, 2)) && !containsHandle(params.args.slice(3))) {
      const value = await resolveHandle(params.args[2], await frameURL(params.targetId, params.frameId), "locator.fill");
      return [[method, { ...params, args: [params.args[0], params.args[1], value, ...params.args.slice(3)] }]];
    }
    if ((method === "input.insertText" && isHandle(params.text)) || (method === "input.key" && isHandle(params.text))) {
      const title = params.typing === "keys" ? "locator.type" : "locator.fill";
      const value = await resolveHandle(params.text, await focusedFrameURL(params.targetId), title);
      if (method === "input.key") return [[method, { ...params, text: value }]];
      const { typing, ...rest } = params;
      if (typing !== "keys") return [[method, { ...rest, text: value }]];
      const calls = [];
      for (const ch of value) {
        if (ns.core.KEYS[ch]) {
          const desc = ns.core.describeKey(ch, new Set());
          for (const type of ["down", "up"]) calls.push(["input.key", { targetId: params.targetId, type, key: desc.key, code: desc.code, text: type === "down" ? desc.text || undefined : undefined, location: desc.location, modifiers: [] }]);
        } else calls.push(["input.insertText", { targetId: params.targetId, text: ch }]);
      }
      return calls;
    }
    throw Object.assign(new Error(`${method}: a secret handle is accepted only as the text of typed input or the value of locator.fill`), { code: "forbidden" });
  }

  async function maskCaptures(targetId, on) {
    const values = [...vault.values()].filter((s) => !s.totp && s.value).map((s) => s.value);
    if (!values.length && on) return;
    const frames = await driver.call("frames.list", { targetId }).catch(() => []);
    for (const f of frames) {
      await driver.call("frame.evaluate", { targetId, frameId: f.frameId, world: "agent", source: agentSource("maskSecrets"), args: [values, on], awaitPromise: true }).catch(() => {});
    }
  }

  const vmCalls = [];
  async function hostedCall(method, params = {}) {
    vmCalls.push({ method, params: JSON.parse(JSON.stringify(params)) });
    await rulesSync;
    if (method === "session.configure" && params && "contentRules" in params) {
      const { contentRules: _ignored, ...rest } = params;
      params = rest;
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
    const calls = await resolveCall(method, params);
    const nav = method === "tab.navigate" && params.targetId;
    if (nav) navigating.set(params.targetId, (navigating.get(params.targetId) || 0) + 1);
    const capture = CAPTURES.has(method) && params.targetId;
    if (capture) await maskCaptures(params.targetId, true);
    try {
      let r;
      for (const [m, p] of calls) r = await driver.call(m, p);
      if (policyActive() && NAVIGATIONS.has(method) && r && r.url && params.url !== "about:blank") {
        const reason = urlReason(r.url);
        if (reason) {
          await blockPage(params.targetId, r.url, reason);
          throw new Error(`${TITLES[method] || method}: navigation to ${r.url} was blocked: ${reason}; the tab now shows about:blank`);
        }
      }
      return BINARY.has(method) ? r : maskValue(r);
    } catch (e) {
      throw maskError(e);
    } finally {
      if (capture) await maskCaptures(params.targetId, false);
      if (nav) {
        const n = (navigating.get(params.targetId) || 1) - 1;
        if (n) navigating.set(params.targetId, n);
        else navigating.delete(params.targetId);
      }
    }
  }

  const hostedDriver = Object.create(driver, {
    call: { value: hostedCall },
    on: { value: (event, handler) => driver.on(event, (payload) => handler(maskValue(payload))) },
  });

  async function policyCheck(targetId) {
    const pending = blocking.get(targetId);
    if (pending) await pending;
    if (!policyActive()) return null;
    const info = await driver.call("tab.info", { targetId }).catch(() => null);
    const reason = info && info.url && urlReason(info.url);
    if (reason) {
      await blockPage(targetId, info.url, reason);
      return maskText(`navigation to ${info.url} was blocked: ${reason}; the tab now shows about:blank`);
    }
    if (pending) {
      const last = log[log.length - 1];
      return maskText(`navigation to ${last.url} was blocked: ${last.reason}; the tab now shows about:blank`);
    }
    return null;
  }

  const hostedHost = Object.create(host, {
    print: { value: (level, text) => host.print(level, maskText(text)) },
    console: { value: { error: (text) => (host.console ? host.console.error(maskText(text)) : host.print("error", maskText(text))) } },
    fsOp: {
      value: (op, args) => {
        if (op === "writeFile" && args && args.base64) args = { ...args, base64: maskBase64(args.base64) };
        return host.fsOp(op, args);
      },
    },
    fetch: {
      value: async (url, init) => {
        checkURL("fetch", url);
        const r = await host.fetch(url, init);
        return { ...r, base64: maskBase64(r.base64) };
      },
    },
    secretSet: { value: (name, value, options) => putSecret(name, value, options, true, "secrets.set") },
    secretList: { value: () => [...vault.keys()].map(describe) },
    secretDelete: {
      value: (name) => {
        const s = vault.get(name);
        if (s && !s.agentKnown) return false;
        const had = vault.delete(name);
        rebuildMasks();
        return had;
      },
    },
    policyNarrow: { value: narrow },
    policyGet: { value: flatPolicy },
    policyLog: { value: () => log.map((e) => ({ ...e })) },
    policyCheck: { value: policyCheck },
  });

  return {
    host: hostedHost,
    driver: hostedDriver,
    maskText,
    maskError,
    // Host operations with origin "user" (browser.secrets.load, policy.set).
    loadUserSecret: (name, value, options) => putSecret(name, value, options, false, "browser.secrets.load"),
    setBasePolicy(policy) {
      base = blank();
      if (policy.allowed) base.allowed = policy.allowed.map((d) => parsePattern(d, "browser.policy.set"));
      if (policy.prohibited) base.prohibited = policy.prohibited.map((d) => parsePattern(d, "browser.policy.set"));
      base.blockIPs = !!policy.blockIPAddresses;
      base.locked = !!policy.lock;
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
