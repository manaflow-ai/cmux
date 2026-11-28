(() => {
  const go = () => { const s = document.createElement("style"); s.textContent = ".cv-fresh{animation:none!important}"; document.head.append(s); };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go); else go();
  let n = 0; new MutationObserver((l) => { for (const r of l) for (const a of r.addedNodes) if (a.nodeType === 1 && (a.classList?.contains("cv-fresh") || a.querySelector?.(".cv-fresh"))) n++; }).observe(document, { childList: true, subtree: true });
  window.__probe = () => ({ v: "nofresh", fresh_adds: n });
})();
