// A/B: followScrollEdges' content observer does nothing (no per-edit rAF read of scrollHeight).
(() => {
  const MO = window.MutationObserver;
  window.MutationObserver = class extends MO { constructor(cb) { super((new Error().stack || "").includes("followScrollEdges") ? () => {} : cb); } };
  window.__probe = () => ({ noedges: true });
})();
