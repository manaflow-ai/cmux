(() => {
  const go = () => { const s = document.createElement("style"); s.textContent = ".acpmux-scroll, .acpmux-scroll *{animation:none!important;transition:none!important}"; document.head.append(s); };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go); else go();
  const raf = window.requestAnimationFrame.bind(window); const blocked = new WeakSet();
  window.requestAnimationFrame = (cb) => { if (!blocked.has(cb) && (new Error().stack || "").includes("startLayoutWatch")) blocked.add(cb); return blocked.has(cb) ? 0 : raf(cb); };
  window.__probe = () => ({ noanimwatch: true });
})();
