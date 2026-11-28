(() => {
  const go = () => { const s = document.createElement("style"); s.textContent = ".acpmux-scroll, .acpmux-scroll *{animation:none!important}"; document.head.append(s); };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go); else go();
  window.__probe = () => ({ v: "noanims" });
})();
