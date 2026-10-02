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
const TEXTUAL = ["json", "xml", "javascript", "x-www-form-urlencoded", "csv", "yaml", "graphql"];

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
    return out;
  }
  function redactValue(value, depth = 0) {
    if (!matchers.length) return value;
    if (typeof value === "string") return redact(value);
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
      if (masks.length) p.secretMasks = masks;
    }
    return p;
  }

  // Wraps a dev driver the way the native session sits in front of the app's.
  function wrapDriver(driver) {
    if (typeof driver.setDomainPolicy === "function") {
      policyListeners.add((p, reason) => driver.setDomainPolicy(p, reason, cookieBlockReason));
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

  // Wraps a dev host: output, written text files and fetch go through the
  // guards; secrets and policy calls reach this boundary.
  function wrapHost(host) {
    const fsOp = host.fsOp;
    const wrapped = Object.create(host);
    Object.assign(wrapped, {
      print: (level, text) => host.print(level, redact(String(text))),
      console: { error: (text) => host.print("error", redact(String(text))) },
      fsOp(op, args) {
        if (op === "writeFile" && matchers.length && args && typeof args.base64 === "string") {
          const text = Buffer.from(args.base64, "base64").toString("utf8");
          if (Buffer.from(text, "utf8").toString("base64") === args.base64) args = { ...args, base64: Buffer.from(redact(text), "utf8").toString("base64") };
        }
        return fsOp(op, args);
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
        const contentType = String((r.headers && (r.headers["content-type"] || r.headers["Content-Type"])) || "").toLowerCase();
        const textual = !contentType || contentType.startsWith("text/") || TEXTUAL.some((t) => contentType.includes(t));
        const out = redactValue({ ...r, base64: undefined });
        out.base64 = textual ? Buffer.from(redact(Buffer.from(r.base64 || "", "base64").toString("utf8")), "utf8").toString("base64") : r.base64;
        return out;
      };
    }
    return wrapped;
  }

  return { redact, redactValue, secretsOp, policyOp, blockReason, prepare, wrapDriver, wrapHost, get policy() {
    return policy;
  } };
}
