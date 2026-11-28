// A/B: endOffscreenMotion's observer and listeners do nothing.
(() => {
  const from = (s) => (new Error().stack || "").includes(s);
  const MO = window.MutationObserver;
  window.MutationObserver = class extends MO { constructor(cb) { super(from("endOffscreenMotion") ? () => {} : cb); } };
  const add = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function (t, cb, o) {
    if ((t === "animationstart" || t === "transitionrun") && from("endOffscreenMotion")) return;
    return add.call(this, t, cb, o);
  };
  window.__probe = () => ({ nooff: true });
})();
