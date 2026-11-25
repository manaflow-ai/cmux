// Diagnostic init script (CMUX_GALLERY_INIT_SCRIPT=scripts/gallery-matrix/dock-trace.js): logs, every frame,
// each bottom-dock box and the transcript's last rows whose top or height changed, plus every running
// animation or transition, as `motion-trace dock ...` console lines (runner.ts echoes them with
// CMUX_GALLERY_ECHO_TRACE=1). It finds what moves the composer on load and the rows at a turn's end.
(() => {
  const last = new Map();
  const anims = new Set();
  let frame = 0;
  const t0 = performance.now();
  const name = (el) => {
    const cls = typeof el.className === "string" ? el.className.trim().split(/\s+/).slice(0, 3).join(".") : "";
    const row = el.getAttribute && (el.getAttribute("data-row-id") || el.getAttribute("data-key") || "");
    return `${el.tagName.toLowerCase()}${cls ? "." + cls : ""}${row ? "[" + row.slice(0, 24) + "]" : ""}`;
  };
  const collect = () => {
    const out = [];
    const dock = document.querySelector(".acpmux-dock");
    if (dock) {
      out.push(dock);
      const walk = (el, depth) => {
        for (const child of el.children) {
          out.push(child);
          if (depth < 3) walk(child, depth + 1);
        }
      };
      walk(dock, 1);
      if (dock.parentElement) out.push(dock.parentElement);
    }
    for (const el of document.querySelectorAll(".acpmux-composer-bar, .acpmux-composer-box, .acpmux-chrome-area")) out.push(el);
    const rows = document.querySelectorAll("article.acpmux-row");
    for (let i = Math.max(0, rows.length - 4); i < rows.length; i++) out.push(rows[i]);
    return [...new Set(out)];
  };
  const tick = () => {
    frame++;
    const ms = Math.round(performance.now() - t0);
    const lines = [];
    const els = collect();
    els.forEach((el, i) => {
      const r = el.getBoundingClientRect();
      const key = `${i}:${name(el)}`;
      const now = `${r.top.toFixed(1)} ${r.height.toFixed(1)}`;
      const was = last.get(key);
      if (was !== now) {
        const cs = getComputedStyle(el);
        const extra = [cs.transform !== "none" ? `tf=${cs.transform}` : "", cs.translate !== "none" ? `tr=${cs.translate}` : "", `pb=${cs.paddingBottom}`, `mb=${cs.marginBottom}`].filter(Boolean).join(" ");
        lines.push(`${key} ${was ?? "-"} -> ${now} ${extra}`);
        last.set(key, now);
      }
    });
    const scroller = document.querySelector(".acpmux-transcript, [data-transcript-scroller]");
    if (scroller) {
      const s = `${Math.round(scroller.scrollTop)}/${Math.round(scroller.scrollHeight)}/${Math.round(scroller.clientHeight)}`;
      if (last.get("scroll") !== s) { lines.push(`scroll ${last.get("scroll") ?? "-"} -> ${s}`); last.set("scroll", s); }
    }
    if (document.getAnimations) {
      for (const a of document.getAnimations()) {
        const target = a.effect && a.effect.target;
        const label = `${a.constructor.name}:${a.transitionProperty || a.animationName || a.id || "waapi"}@${target ? name(target) : "?"}`;
        if (!anims.has(label)) { anims.add(label); lines.push(`anim+ ${label} ${a.effect && a.effect.getTiming ? a.effect.getTiming().duration : ""}`); }
      }
    }
    for (const line of lines) console.log(`motion-trace dock f${frame} t${ms} ${line}`);
    if (ms < 60000) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
})();
