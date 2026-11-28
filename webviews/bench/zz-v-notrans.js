(() => {
  const go = () => { const s = document.createElement("style"); s.textContent = ".acpmux-scroll, .acpmux-scroll *{transition:none!important}"; document.head.append(s); };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go); else go();
  window.__probe = () => ({ v: "notrans" });
})();
