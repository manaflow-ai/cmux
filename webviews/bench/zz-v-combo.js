(() => {
  const MO = window.MutationObserver;
  window.MutationObserver = class extends MO { constructor(cb) { const s = new Error().stack || ""; super(s.includes("followScrollEdges") || s.includes("endOffscreenMotion") ? () => {} : cb); } };
  const add = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function (t, cb, o) {
    if ((t === "animationstart" || t === "transitionrun") && (new Error().stack || "").includes("endOffscreenMotion")) return;
    return add.call(this, t, cb, o);
  };
  window.__probe = () => ({ combo: true });
})();
