// l10n-allow-file: executable chart helper; labels come from agent content.

/// Self-contained SVG charts stay inside the opaque frame (Lucas 2026-10-19). A donut is a stroked
/// ring, so its hole is the page itself in any theme.
export function renderChartSource(): string {
  return `function installCharts() {
    var charts = new Map(), ns = 'http://www.w3.org/2000/svg';
    function node(tag, attrs, text) {
      var el = document.createElementNS(ns, tag);
      Object.keys(attrs || {}).forEach(function (key) {
        if (key === 'fill' || key === 'stroke') el.style.setProperty(key, attrs[key]);
        else el.setAttribute(key, attrs[key]);
      });
      if (text !== undefined) el.textContent = String(text);
      return el;
    }
    function chart(target, options) {
      var el = typeof target === 'string' ? document.querySelector(target) : target;
      if (!el || el.nodeType !== 1) return;
      options = options && typeof options === 'object' ? options : {};
      var labels = Array.isArray(options.labels) ? options.labels.slice(0, 200) : [];
      var series = (Array.isArray(options.series) ? options.series : []).slice(0, 6).filter(function (s) { return s && Array.isArray(s.values); });
      series = series.map(function (s) { return { name: String(s.name || '').replace(/\\d+\\.\\d{6,}/g, function (m) { return String(Number(Number(m).toPrecision(6))); }), values: labels.map(function (_, i) { var v = s.values[i]; return typeof v === 'number' && Number.isFinite(v) ? v : null; }) }; });
      charts.get(el)?.disconnect();
      var height = Math.max(120, Math.min(800, Number(options.height) || 220));
      function cleanup() {
        resize.disconnect();
        if (charts.get(el) === resize) { charts.delete(el); el.replaceChildren(); }
      }
      function draw() {
        if (charts.get(el) !== resize) return;
        if (!el.isConnected) { cleanup(); return; }
        var width = Math.max(180, el.clientWidth || 500), left = 42, right = width - 12, top = 12, bottom = height - 48;
        var svg = node('svg', { width: '100%', height: height, viewBox: '0 0 ' + width + ' ' + height, role: 'img', 'aria-label': options.title || series.map(function (s) { return s.name; }).join(', ') });
        svg.style.cssText = 'display:block;overflow:visible;font:var(--cmux-size-caption) var(--cmux-font);color:var(--cmux-muted)';
        el.replaceChildren(svg);
        function add(tag, attrs, text) { var n = node(tag, attrs, text); svg.append(n); return n; }
        function color(i) { return 'var(--cmux-chart-' + (i % 6 + 1) + ')'; }
        if (!labels.length || !series.length) return;
        var type = options.type || 'line', pie = type === 'donut' || type === 'pie';
        if (pie) {
          var values = series[0].values.map(function (v) { return Math.max(0, v); }), sum = values.reduce(function (a, b) { return a + b; }, 0), angle = -Math.PI / 2;
          var cx = width / 2, cy = (height - 24) / 2, radius = Math.min(width / 3, (height - 48) / 2);
          var ring = type === 'donut', r = ring ? radius * .825 : radius;
          values.forEach(function (v, i) {
            if (!v || !sum) return;
            var end = angle + v / sum * Math.PI * 2, x = cx + r * Math.cos(angle), y = cy + r * Math.sin(angle);
            var arc = 'M' + x + ',' + y + ' A' + r + ',' + r + ' 0 ' + (end - angle > Math.PI ? 1 : 0) + ' 1 ' + (cx + r * Math.cos(end)) + ',' + (cy + r * Math.sin(end));
            var paint = ring ? { fill: 'none', stroke: color(i), 'stroke-width': radius * .35 } : { fill: color(i) };
            var path = sum === v ? add('circle', Object.assign({ cx: cx, cy: cy, r: r }, paint)) : add('path', Object.assign({ d: ring ? arc : 'M' + cx + ',' + cy + ' L' + arc.slice(1) + ' Z' }, paint));
            path.append(node('title', {}, labels[i] + ': ' + v)); angle = end;
          });
        } else {
          var all = series.flatMap(function (s) { return s.values.filter(function (v) { return v !== null; }); }), low = Math.min(0, ...all), high = Math.max(0, ...all);
          var rough = (high - low || 1) / 4, power = Math.pow(10, Math.floor(Math.log10(rough))), unit = rough / power;
          var step = (unit <= 1 ? 1 : unit <= 2 ? 2 : unit <= 5 ? 5 : 10) * power;
          low = Math.floor(low / step) * step; high = Math.ceil(high / step) * step; if (high === low) high = low + step;
          function y(v) { return bottom - (v - low) / (high - low) * (bottom - top); }
          var fmt = new Intl.NumberFormat(undefined, { notation: 'compact', maximumFractionDigits: 1 }), ticks = [];
          for (var tick = low; tick <= high + step / 2; tick += step) ticks.push(tick);
          left = Math.max(28, Math.max.apply(null, ticks.map(function (t) { return fmt.format(t).length; })) * 6.5 + 14);
          var slot = (right - left) / labels.length;
          function x(i) { return left + slot * (i + .5); }
          ticks.forEach(function (tick) {
            var py = y(tick);
            add('line', { x1: left, x2: right, y1: py, y2: py, stroke: 'var(--cmux-border)', 'stroke-width': .5 });
            add('text', { x: left - 8, y: py + 4, fill: 'currentColor', 'text-anchor': 'end' }, fmt.format(Number(tick.toPrecision(5))));
          });
          labels.forEach(function (label, i) { if (i % Math.max(1, Math.ceil(labels.length / Math.max(2, width / 65 | 0))) === 0) add('text', { x: x(i), y: bottom + 18, fill: 'currentColor', 'text-anchor': 'middle' }, String(label).slice(0, 14)); });
          series.forEach(function (s, index) {
            if (type === 'bar') s.values.forEach(function (v, i) { if (v === null) return; var w = slot * .7 / series.length; add('rect', { x: x(i) - slot * .35 + index * w, y: Math.min(y(0), y(v)), width: Math.max(1, w - 2), height: Math.abs(y(v) - y(0)), rx: 2, fill: color(index) }); });
            else {
              var segments = [], segment;
              s.values.forEach(function (v, i) {
                if (v === null) { segment = null; return; }
                if (!segment) { segment = { start: i, end: i, path: 'M' + x(i) + ',' + y(v) }; segments.push(segment); }
                else { segment.path += ' L' + x(i) + ',' + y(v); segment.end = i; }
              });
              var path = segments.map(function (part) { return part.path; }).join(' ');
              if (type === 'area') segments.forEach(function (part) { add('path', { d: part.path + ' L' + x(part.end) + ',' + y(0) + ' L' + x(part.start) + ',' + y(0) + ' Z', fill: color(index), opacity: .12 }); });
              add('path', { d: path, fill: 'none', stroke: color(index), 'stroke-width': 2, 'stroke-linejoin': 'round', 'stroke-linecap': 'round' });
            }
          });
          var cross = add('line', { y1: top, y2: bottom, stroke: 'var(--cmux-muted)', 'stroke-width': .5, visibility: 'hidden' });
          var tip = add('g', { visibility: 'hidden', 'pointer-events': 'none' });
          tip.append(node('rect', { width: 160, height: 24 + series.length * 16, rx: 5, fill: 'var(--cmux-canvas)', stroke: 'var(--cmux-border)' }));
          svg.onpointermove = function (event) {
            var px = (event.clientX - svg.getBoundingClientRect().left) * width / (svg.getBoundingClientRect().width || width);
            var i = Math.max(0, Math.min(labels.length - 1, Math.floor((px - left) / slot)));
            cross.setAttribute('x1', x(i)); cross.setAttribute('x2', x(i)); cross.setAttribute('visibility', 'visible');
            while (tip.childNodes.length > 1) tip.lastChild.remove();
            tip.append(node('text', { x: 8, y: 16, fill: 'var(--cmux-text)' }, String(labels[i]).slice(0, 22)));
            series.forEach(function (s, j) { tip.append(node('text', { x: 8, y: 32 + j * 16, fill: color(j) }, s.name.slice(0, 18) + ': ' + (s.values[i] === null ? '-' : s.values[i].toLocaleString()))); });
            tip.setAttribute('transform', 'translate(' + Math.max(0, Math.min(width - 164, px + 12)) + ',8)'); tip.setAttribute('visibility', 'visible');
          };
          svg.onpointerleave = function () { cross.setAttribute('visibility', 'hidden'); tip.setAttribute('visibility', 'hidden'); };
        }
        var legend = pie ? labels : series.map(function (s) { return s.name; }), at = 0;
        legend.forEach(function (name, i) { if (at + 60 > width) return; add('circle', { cx: at + 4, cy: height - 5, r: 3, fill: color(i) }); add('text', { x: at + 12, y: height - 1, fill: 'currentColor' }, String(name).slice(0, 22)); at += Math.min(22, String(name).length) * 6 + 28; });
      }
      var resize = new ResizeObserver(draw); resize.draw = draw; charts.set(el, resize); resize.observe(el); draw();
      return cleanup;
    }
    window.cmux.chart = chart;
    window.cmux.onTheme(function () { charts.forEach(function (resize) { resize.draw(); }); });
    window.__cmuxCharts = function () {
      document.querySelectorAll('[data-cmux-chart]').forEach(function (el) { try { chart(el, JSON.parse(el.getAttribute('data-cmux-chart'))); } catch (_) {} });
    };
  }`
    .replace(/\n\s*/g, "")
    .replace(/\s*([{}();,=+])\s*/g, "$1");
}
