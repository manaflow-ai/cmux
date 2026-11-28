// A/B: no CSS animation or transition inside the transcript.
(() => {
  const go = () => { const s = document.createElement("style"); s.textContent = ".acpmux-scroll, .acpmux-scroll *{animation:none!important;transition:none!important}"; document.head.append(s); };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go); else go();
  window.__probe = () => ({ noanim: true });
})();
