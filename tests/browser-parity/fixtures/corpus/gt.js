// Ground truth for the corpus checks, written independently of the page
// agent: whether a user can see an element in the engine that runs this.
// `shown(el)` is false when the element is not rendered (display, visibility,
// content-visibility), shows no box of its own or of content not hidden by
// `clip`/`clip-path` (screen-reader-only labels), or lies
// outside the box of an overflow:hidden|clip ancestor along CSS containing
// blocks. `pathOf(el)` is a child-index path from <html>, or null inside a
// frame or shadow root.
function pathOf(el) {
  if (window !== window.top || el.getRootNode() !== document) return null;
  const steps = [];
  for (let e = el; e && e !== document.documentElement; e = e.parentElement) steps.unshift([...e.parentElement.children].indexOf(e));
  return steps.join(".");
}
function byPath(path) {
  let e = document.documentElement;
  for (const i of path.split(".")) e = e && e.children[Number(i)];
  return e || null;
}
function shown(el) {
  if (!el || !el.checkVisibility({ visibilityProperty: true })) return false;
  const clips = (v) => v === "hidden" || v === "clip";
  const box = (e) => e.getBoundingClientRect();
  const r = box(el);
  const own = getComputedStyle(el);
  let visibleBox = r.width >= 1 && r.height >= 1;
  if (!visibleBox && !((r.width < 1 && clips(own.overflowX)) || (r.height < 1 && clips(own.overflowY)))) {
    // Content inside can show, unless `clip` or `clip-path` hides it
    // (screen-reader-only labels).
    const range = document.createRange();
    const hiddenByClip = (cs) => (cs.clip && cs.clip !== "auto") || (cs.clipPath && cs.clipPath !== "none");
    const walk = (node) => {
      for (let n = node.firstChild; n && !visibleBox; n = n.nextSibling) {
        if (n.nodeType === 3 && n.nodeValue.trim()) {
          range.selectNodeContents(n);
          const b = range.getBoundingClientRect();
          visibleBox = b.width >= 1 && b.height >= 1;
        } else if (n.nodeType === 1) {
          const cs = getComputedStyle(n);
          if (cs.display === "none" || hiddenByClip(cs)) continue;
          const b = box(n);
          visibleBox = b.width >= 1 && b.height >= 1;
          if (!visibleBox) walk(n);
        }
      }
    };
    walk(el);
  }
  if (!visibleBox) return false;
  if (!(r.width >= 1 && r.height >= 1)) return true;
  let skip = own.position === "absolute" ? "positioned" : own.position === "fixed" ? "transformed" : null;
  for (let a = el.parentElement; a && a !== document.body && a !== document.documentElement; a = a.parentElement) {
    const cs = getComputedStyle(a);
    const transformed = cs.transform !== "none" || cs.filter !== "none" || /paint|strict|content|layout/.test(cs.contain);
    const positioned = cs.position !== "static" || transformed;
    if (!((skip === "positioned" && !positioned) || (skip === "transformed" && !transformed))) {
      const x = clips(cs.overflowX) || /paint|strict|content/.test(cs.contain);
      const y = clips(cs.overflowY) || /paint|strict|content/.test(cs.contain);
      if (x || y) {
        const b = box(a);
        const left = b.left + a.clientLeft, top = b.top + a.clientTop;
        if ((x && (r.right <= left + 0.5 || r.left >= left + a.clientWidth - 0.5)) ||
            (y && (r.bottom <= top + 0.5 || r.top >= top + a.clientHeight - 0.5))) return false;
      }
      skip = null;
    }
    if (cs.position === "absolute") skip = "positioned";
    else if (cs.position === "fixed") skip = "transformed";
  }
  return true;
}
