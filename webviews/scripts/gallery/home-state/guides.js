// Draws the left edge of each part of Leo's Home over the page and lists them (home-state/spec.json),
// and keeps the numbers on <html data-home-edges> for a check to read.
(() => {
  const textLeft = (el) => {
    if (!el) return undefined;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.textContent.trim()) continue;
      const range = document.createRange();
      range.selectNodeContents(node);
      const rect = range.getClientRects()[0];
      if (rect) return rect.left;
    }
    return el.getBoundingClientRect().left;
  };
  const box = (sel) => document.querySelector(sel)?.getBoundingClientRect();
  const parts = [
    ["card", box(".acpmux-home-inbox")?.left, "#ff4d4d"],
    ["card label", textLeft(document.querySelector(".acpmux-home-inbox .acpmux-home-label")), "#ffa64d"],
    ["card title", textLeft(document.querySelector(".acpmux-home-inbox-ask")), "#ffe14d"],
    ["service line", textLeft(document.querySelector(".acpmux-host-line-message")), "#4dff88"],
    ["picker", box(".acpmux-location-picker svg")?.left ?? box(".acpmux-location-picker")?.left, "#4dd2ff"],
    ["composer", box(".acpmux-composer-strip")?.left, "#b84dff"],
  ];
  const layer = document.createElement("div");
  layer.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:99999;font:11px/1.3 ui-monospace,monospace";
  const list = document.createElement("div");
  list.style.cssText =
    "position:absolute;right:8px;top:8px;padding:6px 8px;background:rgba(0,0,0,.78);color:#fff;border-radius:6px";
  for (const [name, x, color] of parts) {
    if (x === undefined) continue;
    const line = document.createElement("div");
    line.style.cssText = `position:absolute;top:0;bottom:0;left:${x}px;width:1px;background:${color};opacity:.8`;
    layer.append(line);
    const row = document.createElement("div");
    row.innerHTML = `<span style="color:${color}">&#9632;</span> ${name}: ${x.toFixed(1)}`;
    list.append(row);
  }
  layer.append(list);
  document.body.append(layer);
  document.documentElement.dataset.homeEdges = JSON.stringify(Object.fromEntries(parts.map(([n, x]) => [n, x])));
})();
