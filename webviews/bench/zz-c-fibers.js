(() => {
  const counts = {}; let commits = 0, on = false, t0 = 0, fibersSeen = 0;
  const nameOf = (f) => { const t = f.type; if (!t) return null; if (typeof t === "string") return null; return t.displayName || t.name || (t.render && (t.render.displayName || t.render.name)) || (t.type && (t.type.displayName || t.type.name)) || null; };
  const walk = (f) => {
    // Visit fibers that performed work in this commit (flags & PerformedWork=1).
    const stack = [f];
    while (stack.length) {
      const n = stack.pop(); fibersSeen++;
      if ((n.flags & 1) && (typeof n.type === "function" || typeof n.type === "object")) { const k = nameOf(n) || "?"; counts[k] = (counts[k] || 0) + 1; }
      // descend only where work happened below
      if (n.child && (n.subtreeFlags !== 0 || n.flags & 1 || n.alternate === null)) stack.push(n.child);
      if (n.sibling) stack.push(n.sibling);
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
    return { named_per_s: named, v: "fibers", secs: +secs.toFixed(1), commits_per_s: +(commits / secs).toFixed(1), fibers_walked_per_s: Math.round(fibersSeen / secs), renders_per_s: o };
  };
})();
