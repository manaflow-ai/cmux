(() => {
  const counts = {}; let commits = 0, on = false, t0 = 0, fibersSeen = 0;
  const nameOf = (f) => { const t = f.type; if (!t) return null; if (typeof t === "string") return null; return t.displayName || t.name || (t.render && (t.render.displayName || t.render.name)) || (t.type && (t.type.displayName || t.type.name)) || null; };
  const path = {};
  const walk = (root) => {
    // DevTools' rule: a child list the commit did not reconcile is the previous one (child === alternate.child).
    const stack = [[root, ""]];
    while (stack.length) {
      const [n, trail] = stack.pop(); fibersSeen++;
      const prev = n.alternate;
      const fn = typeof n.type === "function" || (typeof n.type === "object" && n.type !== null);
      let here = trail;
      if (fn && (prev === null || (n.flags & 1))) { const k = nameOf(n) || "?"; counts[k] = (counts[k] || 0) + 1; if (!trail) { here = k; path[k] = (path[k] || 0) + 1; } }
      if (n.child && (prev === null || n.child !== prev.child)) { for (let c = n.child; c; c = c.sibling) stack.push([c, here]); }
    }
  };
  let id = 0;
  window.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
    supportsFiber: true, renderers: new Map(), isDisabled: false, checkDCE() {},
    inject(r) { id += 1; this.renderers.set(id, r); return id; },
    onScheduleFiberRoot() {}, onCommitFiberUnmount() {}, onPostCommitFiberRoot() {}, setStrictMode() {},
    onCommitFiberRoot(_id, root) { if (!on) return; commits++; try { walk(root.current); } catch (e) { counts.__err = String(e); } },
  };
  window.addEventListener("keydown", () => { if (!on) { on = true; t0 = performance.now(); try { window.cmuxAcpmuxDebug.renders(); } catch {} } }, true);
  window.__probe = () => {
    const secs = (performance.now() - t0) / 1000;
    const o = {}; for (const k of Object.keys(counts).sort((a, b) => counts[b] - counts[a]).slice(0, 30)) o[k] = +(counts[k] / secs).toFixed(1);
    let named = {}; try { const r = window.cmuxAcpmuxDebug.renders(); for (const k of Object.keys(r).sort((a, b) => r[b] - r[a]).slice(0, 25)) named[k] = +(r[k] / secs).toFixed(1); } catch (e) { named = String(e); }
    const tops = {}; for (const k of Object.keys(path).sort((a, b) => path[b] - path[a]).slice(0, 12)) tops[k] = +(path[k] / secs).toFixed(1);
    return { top_rendered_roots_per_s: tops, named_per_s: named, v: "fibers", secs: +secs.toFixed(1), commits_per_s: +(commits / secs).toFixed(1), fibers_walked_per_s: Math.round(fibersSeen / secs), renders_per_s: o };
  };
})();
