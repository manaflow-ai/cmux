(() => {
  const WATCH = new Set(["AcpmuxPane", "TranscriptView"]);
  const stats = {}; // name -> {renders, props, ctx, hooks:{i:{n, sample}}}
  let on = false, t0 = 0, lastKey = -1e9, commits = 0;
  const nameOf = (f) => { const t = f.type; if (!t || typeof t === "string") return null;
    return t.displayName || t.name || (t.render && (t.render.displayName || t.render.name)) || (t.type && (t.type.displayName || t.type.name)) || null; };
  const desc = (v) => { try {
    if (v === null) return "null"; const t = typeof v;
    if (t === "function") return "fn:" + (v.name || "?");
    if (t !== "object") return t + ":" + String(v).slice(0, 50);
    if (Array.isArray(v)) return "arr" + v.length + (v.length === 2 && Array.isArray(v[1]) ? " memo deps" + v[1].length : "") + ":" + v.slice(0, 2).map((x) => typeof x === "object" && x ? "{" + Object.keys(x).slice(0, 6).join(",") + "}" : String(x).slice(0, 30)).join("|");
    return "{" + Object.keys(v).slice(0, 10).join(",") + "}";
  } catch (e) { return "err"; } };
  const isEffect = (s) => s && typeof s === "object" && "create" in s && "deps" in s;
  const diffDeps = (a, b) => { const out = []; if (!Array.isArray(a) || !Array.isArray(b)) return out;
    for (let i = 0; i < Math.max(a.length, b.length); i++) if (!Object.is(a[i], b[i])) out.push(i + "=" + desc(b[i]).slice(0, 60)); return out; };
  const visit = (n, name) => {
    const s = (stats[name] ||= { renders: 0, afterKey: 0, props: 0, ctx: 0, propKeys: {}, hooks: {}, memoMiss: {} });
    s.renders++;
    if (performance.now() - lastKey < 8) s.afterKey++;
    const p = n.alternate;
    if (n.memoizedProps !== p.memoizedProps) { s.props++;
      const a = p.memoizedProps || {}, b = n.memoizedProps || {};
      for (const k of Object.keys(b)) if (!Object.is(a[k], b[k])) s.propKeys[k] = (s.propKeys[k] || 0) + 1; }
    // context: dependency list memoizedValue changed
    let d = n.dependencies && n.dependencies.firstContext, dp = p.dependencies && p.dependencies.firstContext, ci = 0;
    while (d) { if (dp && !Object.is(d.memoizedValue, dp.memoizedValue)) { s.ctx++; const k = "ctx" + ci + ":" + ((d.context && d.context.displayName) || "?"); s.hooks[k] ||= { n: 0, sample: desc(d.memoizedValue) }; s.hooks[k].n++; }
      d = d.next; dp = dp && dp.next; ci++; }
    let h = n.memoizedState, hp = p.memoizedState, i = 0;
    while (h) { const a = hp ? hp.memoizedState : undefined, b = h.memoizedState;
      if (!isEffect(b) && !Object.is(a, b)) {
        const memo = Array.isArray(b) && b.length === 2 && Array.isArray(b[1]);
        const k = (memo ? "memo" : "st") + i;
        if (memo && Array.isArray(a) && Object.is(a[0], b[0])) {} else {
          s.hooks[k] ||= { n: 0, sample: desc(memo ? b[0] : b), deps: {} }; s.hooks[k].n++;
          if (memo) for (const x of diffDeps(a && a[1], b[1])) s.hooks[k].deps[x.split("=")[0]] = x; }
      }
      h = h.next; hp = hp && hp.next; i++; }
  };
  const walk = (root) => { const stack = [root];
    while (stack.length) { const n = stack.pop(); const prev = n.alternate;
      if (prev && (n.flags & 1)) { const k = nameOf(n); if (k && WATCH.has(k)) visit(n, k); }
      if (n.child && (prev === null || n.child !== prev.child)) for (let c = n.child; c; c = c.sibling) stack.push(c); } };
  let id = 0;
  window.__REACT_DEVTOOLS_GLOBAL_HOOK__ = { supportsFiber: true, renderers: new Map(), isDisabled: false, checkDCE() {},
    inject(r) { id += 1; this.renderers.set(id, r); return id; }, onScheduleFiberRoot() {}, onCommitFiberUnmount() {},
    onPostCommitFiberRoot() {}, setStrictMode() {},
    onCommitFiberRoot(_id, root) { if (!on) return; commits++; try { walk(root.current); } catch (e) { stats.__err = String(e); } } };
  window.addEventListener("keydown", () => { lastKey = performance.now(); if (!on) { on = true; t0 = lastKey; } }, true);
  window.__probe = () => { const secs = (performance.now() - t0) / 1000; const out = { v: "hooks", secs: +secs.toFixed(1), commits_per_s: +(commits / secs).toFixed(1) };
    for (const [k, s] of Object.entries(stats)) { if (k === "__err") { out.err = s; continue; }
      const hooks = Object.entries(s.hooks).sort((a, b) => b[1].n - a[1].n).slice(0, 14).map(([i, v]) => [i, +(v.n / secs).toFixed(1), v.sample, Object.values(v.deps || {}).slice(0, 4)]);
      out[k] = { renders_per_s: +(s.renders / secs).toFixed(1), afterKey_pct: Math.round(100 * s.afterKey / Math.max(1, s.renders)), props_per_s: +(s.props / secs).toFixed(1), propKeys: s.propKeys, ctx_per_s: +(s.ctx / secs).toFixed(1), hooks }; }
    return out; };
})();
