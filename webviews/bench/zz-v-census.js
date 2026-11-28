// Census: which CSS animations/transitions run in the page while keys are typed (sampled every 250 ms).
(() => {
  const seen = new Map(); let samples = 0;
  const name = (el) => !el ? "?" : (el.tagName || "?").toLowerCase() + (typeof el.className === "string" && el.className ? "." + el.className.trim().split(/\s+/).slice(0, 3).join(".") : "");
  setInterval(() => {
    samples++;
    for (const a of document.getAnimations()) {
      if (a.playState !== "running") continue;
      const t = a.effect && a.effect.target;
      const iters = a.effect?.getComputedTiming?.().iterations;
      const k = `${a.constructor.name} ${a.animationName || a.transitionProperty || a.id || "waapi"} iter=${iters} on ${name(t)} < ${name(t?.parentElement)}`;
      seen.set(k, (seen.get(k) || 0) + 1);
    }
  }, 250);
  window.__probe = () => ({ samples, running: [...seen.entries()].sort((a, b) => b[1] - a[1]).slice(0, 25).map(([k, n]) => `${n} ${k}`) });
})();
