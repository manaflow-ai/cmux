import { translate } from "../i18n";

import { literal } from "./renderFrameShell";

export { RENDER_FRAME_DOC, RENDER_POLICY } from "./renderFrameShell";

/// Installed before page scripts on either frame path. It exposes only requests to the card.
export function renderBridgeScript(theme: string, css: string): string {
  // l10n-allow: executable frame bridge, with no user-facing copy
  return `<script>(function () {
    var pending = new Map(), callbacks = new Set(), next = 0;
    var theme = { mode: ${literal(theme)} };
    var style = document.createElement('style');
    style.textContent = ${literal(css)};
    var head = document.head || document.documentElement;
    var policy = head.querySelector('meta[http-equiv="Content-Security-Policy"]');
    head.insertBefore(style, policy ? policy.nextSibling : head.firstChild);
    function request(method, params) {
      return new Promise(function (resolve, reject) {
        var id = String(++next);
        pending.set(id, { resolve: resolve, reject: reject });
        parent.postMessage({ type: 'cmux-render-request', id: id, method: method, params: params }, '*');
      });
    }
    window.cmux = {
      prefill: function (text) { return request('prefill', { text: text }); },
      sendPrompt: function (text) { return request('sendPrompt', { text: text }); },
      copy: function (text) { return request('copy', { text: text }); },
      openLink: function (url) { return request('openLink', { url: url }); },
      theme: theme,
      onTheme: function (callback) { callbacks.add(callback); return function () { callbacks.delete(callback); }; },
      state: {
        get: function () { return request('state.get', {}); },
        set: function (value) { return request('state.set', { value: value }); }
      }
    };
    // Viewport-sized bodies cannot measure their own frame. Follow their in-flow children.
    function size() {
      var body = document.body;
      if (!body) return;
      var style = getComputedStyle(body);
      var top = Infinity, bottom = -Infinity;
      var children = Array.from(body.children).filter(function (child) {
        return !/^(SCRIPT|STYLE|LINK|META|TEMPLATE)$/.test(child.tagName);
      });
      children.forEach(function (child) {
        var position = getComputedStyle(child).position;
        if (position === 'absolute' || position === 'fixed') return;
        var rect = child.getBoundingClientRect();
        if (!rect.height) return;
        top = Math.min(top, rect.top); bottom = Math.max(bottom, rect.bottom);
      });
      var content = bottom > top ? bottom - top : 0;
      var margins = (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0);
      var height = content + (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0) + margins;
      if (!content && (children.length || body.textContent.trim())) height = Math.max(120, height);
      if (Math.ceil(height) === Math.ceil(window.innerHeight + margins)) return;
      parent.postMessage({ type: 'cmux-render-content-size', height: Math.ceil(height) }, '*');
    }
    function observe() {
      var observer = new ResizeObserver(size);
      function children() {
        observer.disconnect();
        observer.observe(document.body);
        observer.observe(document.documentElement);
        Array.from(document.body.children).forEach(function (child) { observer.observe(child); });
        size();
      }
      new window.MutationObserver(children).observe(document.body, { childList: true, subtree: true });
      children();
    }
    if (document.readyState === 'loading') addEventListener('DOMContentLoaded', observe, { once: true });
    else observe();
    addEventListener('load', size);
    addEventListener('message', function (event) {
      var data = event.data;
      if (event.source !== parent || !data) return;
      if (data.type === 'cmux-render-reply') {
        var call = pending.get(data.id);
        if (!call) return;
        pending.delete(data.id);
        if (data.ok) call.resolve(data.value); else call.reject(new Error(data.error));
      } else if (data.type === 'cmux-render-theme' && (data.theme === 'light' || data.theme === 'dark') && typeof data.css === 'string') {
        theme.mode = data.theme;
        style.textContent = data.css;
        callbacks.forEach(function (callback) { try { callback(theme); } catch (_) {} });
      }
    });
  })();</script>`;
}

export const REACT_MARKER = "<!-- cmux-react -->";
export const isReactRender = (html: string) => html.trimStart().startsWith(REACT_MARKER);

/// Compile in the opaque frame, never in the pane. Failures stay readable in the card.
export function reactRenderPage(code: string): string {
  const source = code.trimStart().startsWith(REACT_MARKER) ? code.trimStart().slice(REACT_MARKER.length) : code;
  // l10n-allow: executable component loader; its load failure uses the catalog
  return `<!doctype html><html><head></head><body><div id="root"></div><script>
  (function () {
    var root = document.getElementById('root');
    function fail(error) { root.style.color = 'var(--cmux-muted)'; root.textContent = String(error.message || error); }
    addEventListener('error', function (event) { fail(event.error || event.message); });
    function load(src) {
      return new Promise(function (resolve, reject) {
        var script = document.createElement('script');
        script.src = src; script.onload = resolve;
        script.onerror = function () { reject(new Error(${literal(translate("render.loadFailed"))})); };
        document.head.append(script);
      });
    }
    load('https://unpkg.com/react@18.3.1/umd/react.production.min.js')
      .then(function () { return load('https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js'); })
      .then(function () { return load('https://unpkg.com/@babel/standalone@7.26.4/babel.min.js'); })
      .then(function () {
        var code = Babel.transform(${literal(source)} + '\\nReactDOM.createRoot(document.getElementById("root")).render(React.createElement(App));', { presets: ['react'] }).code;
        new Function(code)();
      }).catch(fail);
  })();</script></body></html>`;
}
