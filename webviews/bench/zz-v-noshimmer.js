(() => {
  const go = () => { const s = document.createElement("style"); s.textContent = ".cv-shimmer__band, .cv-shimmer__band *, .cv-row-shimmer__band, .cv-row-shimmer__band *{animation:none!important}"; document.head.append(s); };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go); else go();
  window.__probe = () => ({ v: "noshimmer" });
})();
