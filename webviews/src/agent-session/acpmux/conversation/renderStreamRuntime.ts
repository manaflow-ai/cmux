/// Installed by the frame's one document write; later tokens keep that document (Lucas 2026-10-18).
export function renderStreamScript(): string {
  // l10n-allow: executable frame runtime, with no user-facing copy.
  return `<script>(function () {
    var previous = null, finished = false, headHTML = '', headNodes = [];
    function attributes(target, source) {
      Array.from(target.attributes).forEach(function (attr) {
        if (!source.hasAttribute(attr.name)) target.removeAttribute(attr.name);
      });
      Array.from(source.attributes).forEach(function (attr) {
        if (target.getAttribute(attr.name) !== attr.value) target.setAttribute(attr.name, attr.value);
      });
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
          if (current) current.replaceWith(added); else target.append(added);
        }
      });
      while (target.childNodes.length > next.length) target.lastChild.remove();
    }
    addEventListener('message', async function (event) {
      var data = event.data;
      if (event.source !== parent || !data || data.type !== 'cmux-render-stream' || typeof data.html !== 'string' || finished) return;
      var done = data.done === true;
      if (!done && data.html === previous) return;
      previous = data.html;
      if (done) finished = true;
      var page = new DOMParser().parseFromString(data.html, 'text/html');
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
          if (/^on/i.test(attr.name) || /^\\s*javascript:/i.test(attr.value)) node.removeAttribute(attr.name);
        });
      });
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
      if (document.body.innerHTML !== page.body.innerHTML) sync(document.body, page.body);
      if (!done) return;
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
    });
    parent.postMessage({ type: 'cmux-render-stream-ready' }, '*');
  })();</script>`;
}
