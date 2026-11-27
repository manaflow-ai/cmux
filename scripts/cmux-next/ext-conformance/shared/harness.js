// Shared by every conformance context (MV3 service worker, extension pages,
// MV2 background page). Results go to the ext-e2e.py collector, whose URL the
// runner writes into config.json next to the manifest.
//
// Status values:
//   pass         the call behaved as Chrome documents
//   fail         it threw, timed out, or returned the wrong thing
//   unsupported  the namespace or feature is absent (chrome.X is undefined)
//   pending      needs a runner step (UI) before it can finish
"use strict";

const CXT = (() => {
  let configPromise = null;
  const suite = (() => {
    try {
      return chrome.runtime.getManifest().manifest_version === 2 ? "mv2" : "mv3";
    } catch (e) {
      return "unknown";
    }
  })();

  function config() {
    if (!configPromise) {
      configPromise = fetch(chrome.runtime.getURL("config.json")).then((r) => r.json());
    }
    return configPromise;
  }

  async function post(path, body) {
    const cfg = await config();
    await fetch(cfg.collector + path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(Object.assign({ run: cfg.run, suite }, body)),
    });
  }

  function text(value) {
    if (value === undefined) return "";
    if (typeof value === "string") return value.slice(0, 400);
    try {
      return JSON.stringify(value).slice(0, 400);
    } catch (e) {
      return String(value).slice(0, 400);
    }
  }

  function report(api, test, status, detail) {
    return post("/r", { api, test, status, detail: text(detail) }).catch(() => {});
  }

  function timeout(promise, ms, label) {
    let timer;
    return Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("timeout after " + ms + " ms: " + label)), ms);
      }),
    ]).finally(() => clearTimeout(timer));
  }

  // Namespace lookup: "tabGroups" or "storage.session".
  function namespace(path) {
    return path.split(".").reduce((node, key) => (node == null ? undefined : node[key]), chrome);
  }

  // Runs one test. `fn` returns a value (pass, value becomes detail), or an
  // object {status, detail} to override the verdict. A missing namespace is
  // "unsupported" without calling fn.
  async function test(api, name, fn, options = {}) {
    const need = options.needs === undefined ? api : options.needs;
    if (need && namespace(need) === undefined) {
      await report(api, name, "unsupported", "chrome." + need + " is undefined");
      return;
    }
    try {
      const value = await timeout(Promise.resolve().then(fn), options.timeout || 30000, api + "." + name);
      if (value && typeof value === "object" && typeof value.status === "string") {
        await report(api, name, value.status, value.detail);
      } else {
        await report(api, name, "pass", value);
      }
    } catch (error) {
      await report(api, name, "fail", (error && error.message) || String(error));
    }
  }

  function expect(condition, message) {
    if (!condition) throw new Error(message);
  }

  function event(target, ms, label, filter = () => true) {
    return timeout(
      new Promise((resolve) => {
        const listener = (...args) => {
          if (!filter(...args)) return;
          target.removeListener(listener);
          resolve(args);
        };
        target.addListener(listener);
      }),
      ms,
      label,
    );
  }

  return { config, post, report, test, expect, event, timeout, suite, text };
})();

if (typeof self !== "undefined") self.CXT = CXT;
