// The native side of a REPL session's guards, in Node, for the dev backend.
//
// In the app these live in Swift (BrowserReplBoundary, BrowserReplSecretStore,
// BrowserReplDomainPolicy in Packages/macOS/CmuxBrowser): secret values, the
// domain policy and redaction sit between the REPL's JavaScriptCore context
// and the driver, so agent code cannot switch them off. This module mirrors
// that contract for the runtime under test on the Playwright dev driver; it is
// test infrastructure, not a boundary (it shares Node's realm).
const PREPARED = ["input.insertText", "tab.navigate", "tabs.open", "session.configure", "tab.screenshot", "tab.pdf"];
const BINARY = new Set(["tab.screenshot", "tab.pdf"]);
const RESERVED = ["secretName", "secretDomains", "secretMasks"];
// Windows on each side of the current one whose TOTP codes a server still
// accepts (BrowserReplSecretStore.totpSkewWindows).
const TOTP_SKEW = 1;
const TOTP_PERIOD_MS = 30_000;

export class BoundaryError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

import { siteOf } from "./public-suffix.mjs";

const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const htmlEscape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// `T` is the runtime's agentTools namespace (pure pattern and TOTP helpers).
export function createBoundary(T, { now = () => Date.now() } = {}) {
  const store = new Map(); // name -> { value, domains, totp }
  let policy = { allowed: null, prohibited: [], blockIPs: false, locked: false };
  const policyListeners = new Set();
  let matchers = [];

  function rebuild() {
    codeCache = null;
    matchers = [...store.entries()]
      .sort((a, b) => b[1].value.length - a[1].value.length)
      .map(([name, s]) => {
        const v = s.value;
        const html = htmlEscape(v);
        const literals = [...new Set([v, JSON.stringify(v).slice(1, -1), html, html.replace(/'/g, "&#39;"), html.replace(/'/g, "&#x27;")])].filter(Boolean).sort((a, b) => b.length - a.length);
        const encoded = [...v]
          .map((ch) => {
            const hex = [...Buffer.from(ch, "utf8")].map((b) => "%" + b.toString(16).toUpperCase().padStart(2, "0").replace(/[A-F]/g, (c) => `[${c}${c.toLowerCase()}]`)).join("");
            const options = [escapeRegExp(ch), hex];
            if (ch === " ") options.push("\\+");
            return `(?:${options.join("|")})`;
          })
          .join("");
        return { mask: `<secret:${name}>`, bytes: Buffer.from(v, "utf8"), literals, encoded: new RegExp(encoded, "g") };
      });
  }

  // The codes of every TOTP secret a server can still accept now, once per window.
  let codeCache = null;
  function validCodes() {
    const window = Math.floor(now() / TOTP_PERIOD_MS);
    if (codeCache && codeCache.window === window) return codeCache.codes;
    const codes = [...store.entries()]
      .filter(([, s]) => s.totp)
      .map(([name, s]) => {
        const list = [...new Set(Array.from({ length: 2 * TOTP_SKEW + 1 }, (_, i) => T.totp(s.value, (window + i - TOTP_SKEW) * TOTP_PERIOD_MS)))].sort();
        return { mask: `<secret:${name}>`, codes: list, domains: s.domains, pattern: new RegExp(`(?<![0-9])(?:${list.join("|")})(?![0-9])`, "g") };
      });
    codeCache = { window, codes };
    return codes;
  }

  function redact(text) {
    if (!matchers.length || typeof text !== "string" || !text) return text;
    let out = text.replace(/[A-Za-z0-9+/_-]{8,}={0,2}/g, (token) => {
      const b64 = token.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
      const decoded = Buffer.from(b64 + "=".repeat((4 - (b64.length % 4)) % 4), "base64");
      const hit = matchers.find((m) => decoded.includes(m.bytes));
      return hit ? hit.mask : token;
    });
    for (const m of matchers) {
      for (const lit of m.literals) if (out.includes(lit)) out = out.split(lit).join(m.mask);
      if (/[%+]/.test(out)) out = out.replace(m.encoded, m.mask);
    }
    if (/[0-9]/.test(out)) for (const c of validCodes()) out = out.replace(c.pattern, c.mask);
    return out;
  }
  // As BrowserReplSecretStore.redact(Data): UTF-8 is redacted as text; other
  // bytes get each value's UTF-8 and escaped forms replaced, then the ASCII
  // forms matched over a Latin-1 view (one character per byte).
  const utf8 = new TextDecoder("utf-8", { fatal: true });
  function redactBytes(buf) {
    if (!matchers.length || !buf.length) return buf;
    let text = null;
    try {
      text = utf8.decode(buf);
    } catch {}
    if (text !== null) {
      const out = redact(text);
      return out === text ? buf : Buffer.from(out, "utf8");
    }
    let out = buf;
    for (const m of matchers) {
      const mask = Buffer.from(m.mask, "utf8");
      for (const lit of m.literals) {
        const needle = Buffer.from(lit, "utf8");
        if (!out.includes(needle)) continue;
        const parts = [];
        let start = 0;
        for (let at = out.indexOf(needle); at !== -1; at = out.indexOf(needle, start)) {
          parts.push(out.subarray(start, at), mask);
          start = at + needle.length;
        }
        parts.push(out.subarray(start));
        out = Buffer.concat(parts);
      }
    }
    const latin = out.toString("latin1");
    const redacted = redact(latin);
    return redacted === latin ? out : Buffer.from(redacted, "latin1");
  }
  const redactBase64 = (b64) => {
    const buf = Buffer.from(b64 || "", "base64");
    const out = redactBytes(buf);
    return out === buf ? b64 : out.toString("base64");
  };
  function redactValue(value, depth = 0) {
    if (!matchers.length) return value;
    if (typeof value === "string") return redact(value);
    if (typeof value === "number" && Number.isFinite(value)) {
      // A page can read a code as a number, which drops a leading zero.
      const forms = [String(value)];
      if (Number.isInteger(value) && value >= 0 && value < 1e6) forms.push(String(value).padStart(6, "0"));
      for (const form of forms) {
        const masked = redact(form);
        if (masked !== form) return masked;
      }
      return value;
    }
    if (!value || typeof value !== "object" || depth > 64 || Buffer.isBuffer(value)) return value;
    if (Array.isArray(value)) return value.map((v) => redactValue(v, depth + 1));
    const proto = Object.getPrototypeOf(value);
    if (proto !== Object.prototype && proto !== null) return value;
    const out = {};
    for (const k of Object.keys(value)) out[redact(k)] = redactValue(value[k], depth + 1);
    return out;
  }

  function setSecret(name, value, domains, totp, title) {
    if (typeof name !== "string" || !/^[\w.-]{1,64}$/.test(name)) throw new BoundaryError("invalid", `${title}: name: expected letters, digits, _, . or - (at most 64), got ${JSON.stringify(name)}`);
    if (typeof value !== "string" || !value) throw new BoundaryError("invalid", `${title}: ${name}: value: expected a non-empty string`);
    if (!Array.isArray(domains) || !domains.length) throw new BoundaryError("invalid", `${title}: ${name}: domains: expected the domains it may be typed into, such as ["example.com"]; a secret without domains is not accepted`);
    const parsed = domains.map((d) => {
      try {
        return T.parsePattern(d, title);
      } catch (e) {
        throw new BoundaryError("invalid", e.message);
      }
    });
    const isTotp = !!totp || /bu_2fa_code$/.test(name);
    if (isTotp) {
      try {
        T.base32Decode(value);
      } catch {
        throw new BoundaryError("invalid", "secrets: a TOTP secret must be base32");
      }
    }
    store.set(name, { value, domains: parsed, totp: isTotp });
    rebuild();
  }
  const describe = (name) => {
    const s = store.get(name);
    return { name, domains: s.domains.map((d) => d.raw), totp: s.totp };
  };

  function secretsOp(op, args = {}, { readFile } = {}) {
    switch (op) {
      case "set":
        setSecret(args.name, args.value, args.domains || [], args.totp, "secrets.set");
        return describe(args.name);
      case "load": {
        let data = args.object;
        if (args.path !== undefined) {
          const text = readFile(args.path);
          try {
            data = JSON.parse(text);
          } catch {
            throw new BoundaryError("invalid", `secrets.load: ${args.path} is not JSON`);
          }
        }
        if (!data || typeof data !== "object" || Array.isArray(data)) throw new BoundaryError("invalid", 'secrets.load: expected { "<domain pattern>": { name: value } }');
        const names = [];
        for (const pattern of Object.keys(data).sort()) {
          const entries = data[pattern];
          if (!entries || typeof entries !== "object") throw new BoundaryError("invalid", `secrets.load: ${JSON.stringify(pattern)}: a secret needs domains; expected { "<domain pattern>": { name: value } }`);
          for (const name of Object.keys(entries).sort()) {
            const v = entries[name];
            const value = v && typeof v === "object" ? v.value : v;
            const prior = store.get(name);
            const domains = prior && prior.value === value ? [...prior.domains.map((d) => d.raw), pattern] : [pattern];
            setSecret(name, value, domains, !!(v && typeof v === "object" && v.totp) || (prior && prior.totp), "secrets.load");
            if (!names.includes(name)) names.push(name);
          }
        }
        return names.map(describe);
      }
      case "list":
        return [...store.keys()].map(describe);
      case "has":
        return store.has(args.name);
      case "delete": {
        const had = store.delete(args.name);
        rebuild();
        return had;
      }
      case "clear":
        store.clear();
        rebuild();
        return null;
      default:
        throw new BoundaryError("invalid", `secrets: unknown operation ${op}`);
    }
  }

  const active = () => !!(policy.allowed || policy.prohibited.length || policy.blockIPs);
  function blockReason(url) {
    if (!active()) return null;
    const s = String(url);
    if (/^(about:|data:|blob:)/i.test(s)) return null;
    const target = /^[a-z][a-z0-9+.-]*:/i.test(s) ? s : "https://" + s;
    let u;
    try {
      u = new URL(target);
    } catch {
      return "not a valid URL";
    }
    const host = T.normalizeHost(u.hostname);
    if (!host) return `its scheme ${u.protocol} has no host`;
    if (policy.blockIPs && T.isIPHost(host)) return "IP addresses are blocked (session.blockIPAddresses)";
    if (policy.allowed && !policy.allowed.some((p) => T.urlMatches(target, p, false))) return `not in session.allowedDomains (${policy.allowed.map((p) => p.raw).join(", ")})`;
    const hit = policy.prohibited.find((p) => T.urlMatches(target, p, false));
    if (hit) return `prohibited by ${hit.raw} (session.prohibitedDomains)`;
    return null;
  }
  // Why a cookie on `domain` is out of the session's reach, as
  // BrowserReplDomainPolicy.cookieBlockReason: hosts, not origins, so a
  // pattern's scheme and port do not narrow it; an allowed pattern covers a
  // cookie its host receives (on the host or a parent domain of it).
  function cookieBlockReason(domain) {
    if (!active()) return null;
    const host = T.normalizeHost(String(domain || "").replace(/^\.+/, ""));
    if (!host) return "the cookie names no domain";
    if (policy.blockIPs && T.isIPHost(host)) return "IP addresses are blocked (session.blockIPAddresses)";
    const hostOnly = (p) => ({ ...p, scheme: null, port: null });
    const names = (p, h) => T.urlMatches(`http://${h}/`, hostOnly(p), false);
    const receives = (p) => {
      if (names(p, host) || p.host === "*") return true;
      const named = String(p.host).replace(/^\*\./, "");
      return named.endsWith("." + host);
    };
    if (policy.allowed && !policy.allowed.some(receives)) return `not in session.allowedDomains (${policy.allowed.map((p) => p.raw).join(", ")})`;
    const hit = policy.prohibited.find((p) => names(p, host));
    if (hit) return `prohibited by ${hit.raw} (session.prohibitedDomains)`;
    return null;
  }
  // BrowserReplDomainPolicy.cookieSetBlockReason: a cookie with a Domain
  // attribute (leading dot) reaches every subdomain, so an allowed pattern
  // must cover all of them and no prohibited host may be among them.
  function cookieSetBlockReason(domain) {
    const base = cookieBlockReason(domain);
    if (base || !active()) return base;
    const raw = String(domain || "").trim();
    if (!raw.startsWith(".")) {
      const host = T.normalizeHost(raw);
      const hostOnly = (p) => ({ ...p, scheme: null, port: null });
      if (policy.allowed && !policy.allowed.some((p) => T.urlMatches(`http://${host}/`, hostOnly(p), false))) return `not in session.allowedDomains (${policy.allowed.map((p) => p.raw).join(", ")})`;
      return null;
    }
    const host = T.normalizeHost(raw.replace(/^\.+/, ""));
    const covers = (p) => p.host === "*" || (p.host.startsWith("*.") && (host === p.host.slice(2) || host.endsWith("." + p.host.slice(2))));
    if (policy.allowed && !policy.allowed.some(covers)) return `a cookie on ${host} reaches its other subdomains, which session.allowedDomains (${policy.allowed.map((p) => p.raw).join(", ")}) does not all allow; set it on the allowed host itself`;
    const under = (p) => {
      if (p.host === "*") return true;
      const named = String(p.host).replace(/^\*\./, "");
      return named === host || named.endsWith("." + host) || host.endsWith("." + named);
    };
    const hit = policy.prohibited.find(under);
    if (hit) return `a cookie on ${host} reaches ${hit.raw} (session.prohibitedDomains)`;
    return null;
  }
  const policyJSON = () => ({ allowed: policy.allowed ? policy.allowed.map((p) => p.raw) : null, prohibited: policy.prohibited.map((p) => p.raw), blockIPs: policy.blockIPs, locked: policy.locked });
  function policyOp(op, args = {}) {
    if (op === "get") return policyJSON();
    if (op === "check") return blockReason(args.url || "");
    if (op === "site") return siteOf(args.host || "");
    if (op !== "set") throw new BoundaryError("invalid", `policy: unknown operation ${op}`);
    const title = args.title || "session.domainPolicy";
    if (policy.locked) throw new BoundaryError("invalid", `${title}: the domain policy is locked for this session`);
    const parse = (list) => {
      if (list === null || list === undefined) return null;
      if (!Array.isArray(list)) throw new BoundaryError("invalid", `${title}: expected an array of domain patterns or null, got ${JSON.stringify(list)}`);
      return list.map((d) => {
        try {
          return T.parsePattern(d, title);
        } catch (e) {
          throw new BoundaryError("invalid", e.message);
        }
      });
    };
    const next = { ...policy };
    if ("allowed" in args) {
      const l = parse(args.allowed);
      next.allowed = l && l.length ? l : null;
    }
    if ("prohibited" in args) next.prohibited = parse(args.prohibited) || [];
    if (typeof args.blockIPs === "boolean") next.blockIPs = args.blockIPs;
    if (args.lock) next.locked = true;
    policy = next;
    for (const fn of policyListeners) fn(policy, blockReason);
    return policyJSON();
  }

  function prepare(method, params = {}) {
    if (!PREPARED.includes(method)) return params;
    const p = { ...params };
    for (const k of RESERVED) delete p[k];
    if (method === "input.insertText" && "secret" in p) {
      const name = p.secret;
      delete p.secret;
      const s = store.get(name);
      if (!s) throw new BoundaryError("invalid", `secret ${JSON.stringify(name)} was deleted`);
      p.text = s.totp ? T.totp(s.value, now()) : s.value;
      p.secretName = name;
      p.secretDomains = s.domains;
    } else if ((method === "tab.navigate" || method === "tabs.open") && p.url) {
      const reason = blockReason(p.url);
      if (reason) throw new BoundaryError("blocked", `${p.url} is blocked: ${reason}`);
    } else if (method === "session.configure" && "contentRules" in p) {
      throw new BoundaryError("invalid", "session.configure: content rules come from the domain policy (session.allowedDomains, session.prohibitedDomains, session.blockIPAddresses)");
    } else if ((method === "tab.screenshot" || method === "tab.pdf") && store.size) {
      const masks = [...store.values()].filter((s) => !s.totp).map((s) => ({ value: s.value, domains: s.domains }));
      for (const c of validCodes()) for (const value of c.codes) masks.push({ value, domains: c.domains });
      if (masks.length) p.secretMasks = masks;
    }
    return p;
  }

  // Wraps a dev driver the way the native session sits in front of the app's.
  function wrapDriver(driver) {
    if (typeof driver.setDomainPolicy === "function") {
      policyListeners.add((p, reason) => driver.setDomainPolicy(p, reason, cookieBlockReason, cookieSetBlockReason));
    }
    const redactError = (e) => {
      if (e && typeof e.message === "string" && matchers.length) e.message = redact(e.message);
      return e;
    };
    return {
      get name() {
        return driver.name;
      },
      async call(method, params) {
        const prepared = prepare(method, params || {});
        try {
          const r = await driver.call(method, prepared);
          return BINARY.has(method) ? r : redactValue(r);
        } catch (e) {
          throw redactError(e);
        }
      },
      on: (event, handler) => driver.on(event, (payload) => handler(redactValue(payload))),
      capabilities: () => driver.capabilities(),
      detach: () => driver.detach(),
    };
  }

  // Wraps a dev host: output, written and read files and fetch go through
  // the guards; secrets and policy calls reach this boundary.
  function wrapHost(host) {
    const fsOp = host.fsOp;
    const wrapped = Object.create(host);
    Object.assign(wrapped, {
      print: (level, text) => host.print(level, redact(String(text))),
      console: { error: (text) => host.print("error", redact(String(text))) },
      fsOp(op, args) {
        if (op === "writeFile" && matchers.length && args && typeof args.base64 === "string") {
          args = { ...args, base64: redactBase64(args.base64) };
        }
        const result = fsOp(op, args);
        return op === "readFile" && typeof result === "string" ? redactBase64(result) : result;
      },
      secrets: (op, args) => secretsOp(op, args, { readFile: (p) => Buffer.from(fsOp("readFile", { path: p }), "base64").toString("utf8") }),
      policy: (op, args) => policyOp(op, args),
    });
    if (typeof host.fetch === "function") {
      const fetch = host.fetch.bind(host);
      wrapped.fetch = async (url, init = {}) => {
        const reason = blockReason(url);
        if (reason) throw new BoundaryError("blocked", `fetch: ${url} is blocked: ${reason}`);
        const r = await fetch(url, { ...init, blockReason });
        if (!matchers.length) return r;
        const out = redactValue({ ...r, base64: undefined });
        out.base64 = redactBase64(r.base64);
        return out;
      };
    }
    return wrapped;
  }

  return { redact, redactValue, secretsOp, policyOp, blockReason, prepare, wrapDriver, wrapHost, get policy() {
    return policy;
  } };
}
