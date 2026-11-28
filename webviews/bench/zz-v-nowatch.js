// A/B: layoutWatch's per-frame tick never runs.
(() => {
  const raf = window.requestAnimationFrame.bind(window);
  const blocked = new WeakSet(); let n = 0;
  window.requestAnimationFrame = (cb) => {
    if (!blocked.has(cb) && (new Error().stack || "").includes("startLayoutWatch")) blocked.add(cb);
    if (blocked.has(cb)) { n++; return 0; }
    return raf(cb);
  };
  window.__probe = () => ({ nowatch_blocked: n });
})();
