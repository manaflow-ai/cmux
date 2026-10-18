/// Ordered execution with parallel fetches; a fence can warm only its own unused frame.
export function reactDependenciesSource(): string {
  // l10n-allow: executable dependency loader; the pane supplies the catalog error.
  return `function prepareReact(errorText) {
    if (window.__cmuxReactReady) return window.__cmuxReactReady;
    function load(src) {
      return new Promise(function (resolve, reject) {
        var script = document.createElement('script');
        script.src = src; script.async = false; script.onload = resolve;
        script.onerror = function () { reject(new Error(errorText)); };
        document.head.append(script);
      });
    }
    window.__cmuxReactReady = Promise.all([
      load('https://unpkg.com/react@18.3.1/umd/react.production.min.js'),
      load('https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js'),
      load('https://unpkg.com/@babel/standalone@7.26.4/babel.min.js')
    ]);
    window.__cmuxReactReady.catch(function () {});
    return window.__cmuxReactReady;
  }`;
}

/// Installed in the static shell or native replacement; later tokens keep that document.
export function renderStreamScript(): string {
  // l10n-allow: executable frame runtime, with no user-facing copy.
  return `<script>(function () {
    ${reactDependenciesSource()}
    var previous = null, finished = false, headHTML = '', headNodes = [], appendable = false;
    function complete(page, html) {
      var tail = page.body.lastChild;
      if (!html.endsWith('>') || !tail || tail.nodeType !== 1) return false;
      if (!/^(AREA|BR|COL|EMBED|HR|IMG|INPUT|PARAM|SOURCE|TRACK|WBR)$/.test(tail.tagName) &&
          !html.endsWith('</' + tail.localName + '>')) return false;
      return html === page.head.innerHTML + page.body.innerHTML;
    }
    function attributes(target, source) {
      Array.from(target.attributes).forEach(function (attr) {
        if (!source.hasAttribute(attr.name)) target.removeAttribute(attr.name);
      });
      Array.from(source.attributes).forEach(function (attr) {
        if (target.getAttribute(attr.name) !== attr.value) target.setAttribute(attr.name, attr.value);
      });
    }
    function enter(node) {
      if (!window.__cmuxRenderKit || !node.animate || !window.matchMedia || window.matchMedia('(prefers-reduced-motion: reduce)').matches || /^(SCRIPT|STYLE|LINK|META)$/.test(node.tagName)) return;
      node.animate([{ opacity: 0, transform: 'translateY(3px)' }, { opacity: 1, transform: 'translateY(0)' }], { duration: 150, easing: 'ease-out' });
    }
    function sync(target, source) {
      var next = Array.from(source.childNodes);
      next.forEach(function (node, index) {
        var current = target.childNodes[index];
        if (current && current.isEqualNode(node)) return;
        if (current && current.nodeType === 3 && node.nodeType === 3) {
          current.textContent = node.textContent;
        } else if (current && current.nodeType === 1 && node.nodeType === 1 && current.tagName === node.tagName) {
          attributes(current, node);
          sync(current, node);
        } else {
          var added = document.importNode(node, true);
          if (current) current.replaceWith(added); else { target.append(added); enter(added); }
        }
      });
      while (target.childNodes.length > next.length) target.lastChild.remove();
    }
    addEventListener('message', async function (event) {
      var data = event.data;
      if (event.source === parent && data && data.type === 'cmux-render-react-prepare') {
        prepareReact(typeof data.errorText === 'string' ? data.errorText : '');
        return;
      }
      if (event.source !== parent || !data || data.type !== 'cmux-render-stream' || typeof data.html !== 'string' || finished) return;
      var done = data.done === true;
      if (!done && data.html === previous) return;
      var suffix = previous !== null && data.html.startsWith(previous) ? data.html.slice(previous.length) : '';
      var append = !done && appendable && suffix.endsWith('>');
      var page = new DOMParser().parseFromString(append ? suffix : data.html, 'text/html');
      // Canonical fragments have no parser-repaired open ancestors, raw-text tails or entities.
      // Anything ambiguous uses the full parser and diff, including final script activation.
      if (append && (page.head.childNodes.length || suffix !== page.body.innerHTML)) {
        append = false;
        page = new DOMParser().parseFromString(data.html, 'text/html');
      }
      appendable = append || complete(page, data.html);
      previous = data.html;
      if (done) finished = true;
      var scripts = Array.from(page.querySelectorAll('script'));
      var originals = scripts.map(function (script) { return script.cloneNode(true); });
      scripts.forEach(function (script, index) {
        if (!done) script.remove();
        else {
          script.removeAttribute('src');
          script.type = 'application/cmux-inert';
          script.setAttribute('data-cmux-stream-script', String(index));
        }
      });
      if (!done) page.querySelectorAll('*').forEach(function (node) {
        Array.from(node.attributes).forEach(function (attr) {
          var url = attr.value.replace(/[\\t\\n\\r]/g, '').replace(/^[\\x00-\\x20]+/, '');
          if (/^on/i.test(attr.name) || /^javascript:/i.test(url)) node.removeAttribute(attr.name);
        });
      });
      if (append) {
        var body = document.body;
        Array.from(page.body.childNodes).forEach(function (node) { var added = document.importNode(node, true); body.append(added); enter(added); });
        return;
      }
      var styles = Array.from(page.head.querySelectorAll('style, link[rel="stylesheet"]'));
      var css = styles.map(function (node) { return node.outerHTML; }).join('');
      if (css !== headHTML) {
        headNodes.forEach(function (node) { node.remove(); });
        headNodes = styles.map(function (node) { return document.importNode(node, true); });
        headNodes.forEach(function (node) { document.head.append(node); });
        headHTML = css;
      }
      // Keep matching elements and growing text nodes, including their selection and focus.
      attributes(document.documentElement, page.documentElement);
      attributes(document.body, page.body);
      sync(document.body, page.body);
      if (!done) return;
      window.__cmuxScriptsRun = true;
      if (window.__cmuxRenderKit && window.__cmuxCharts) window.__cmuxCharts();
      for (var index = 0; index < originals.length; index++) {
        var original = originals[index];
        var placeholder = document.body.querySelector('script[data-cmux-stream-script="' + index + '"]');
        var script = document.createElement('script');
        Array.from(original.attributes).forEach(function (attr) { script.setAttribute(attr.name, attr.value); });
        script.textContent = original.textContent;
        var loaded = script.src || script.type === 'module' ? new Promise(function (resolve) {
          script.onload = resolve; script.onerror = resolve;
        }) : null;
        script.async = false;
        if (placeholder) placeholder.replaceWith(script); else document.head.append(script);
        if (loaded) await loaded;
      }
      document.dispatchEvent(new Event('DOMContentLoaded', { bubbles: true }));
      window.dispatchEvent(new Event('load'));
      if (window.__cmuxReactReady) await window.__cmuxReactReady;
      document.dispatchEvent(new Event('cmux-render-settled'));
    });
    function ready() { parent.postMessage({ type: 'cmux-render-stream-ready' }, '*'); }
    if (document.readyState === 'loading') addEventListener('DOMContentLoaded', ready, { once: true });
    else ready();
  })();</script>`;
}
