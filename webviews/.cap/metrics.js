(() => {
  const md =
    document.querySelector(".cv-md.cv-reply") ||
    document.querySelectorAll(".cv-md")[1] ||
    document.querySelector(".cv-md");
  if (!md) {
    document.body.innerHTML = "<pre>no .cv-md</pre>";
    return;
  }
  const col = md.getBoundingClientRect();
  const lines = [
    `column left=${col.left.toFixed(1)} width=${col.width.toFixed(1)} gap=${getComputedStyle(md).rowGap} display=${getComputedStyle(md).display}`,
  ];
  let prev = null;
  for (const el of md.children) {
    const r = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    const inner = el.querySelector(
      ".cv-diagram__chart svg, .cv-thumb, table, .katex-display, .katex, .cv-codeblock__body, svg",
    );
    const ir = inner ? inner.getBoundingClientRect() : null;
    const name = el.tagName.toLowerCase() + "." + [...el.classList].join(".");
    const space = prev ? (r.top - prev.bottom).toFixed(1) : "-";
    lines.push(
      `${name.padEnd(48)} spaceAbove=${space.padStart(6)} m=${cs.marginTop}/${cs.marginBottom} box=[${(r.left - col.left).toFixed(0)},${(col.right - r.right).toFixed(0)}] w=${r.width.toFixed(0)}` +
        (ir
          ? ` inner=${inner.tagName.toLowerCase()}.${inner.classList[0] || ""} [L${(ir.left - col.left).toFixed(0)} R${(col.right - ir.right).toFixed(0)}] w=${ir.width.toFixed(0)}`
          : "") +
        ` sw=${el.scrollWidth} cw=${el.clientWidth}`,
    );
    prev = r;
  }
  // anything wider than the column
  const over = [...md.querySelectorAll("*")]
    .filter((e) => {
      const r = e.getBoundingClientRect();
      return r.width > 0 && r.right > col.right + 1;
    })
    .slice(0, 15);
  lines.push("", "past column right edge:");
  for (const e of over) {
    const r = e.getBoundingClientRect();
    lines.push(`  ${e.tagName.toLowerCase()}.${[...e.classList].join(".")} right+${(r.right - col.right).toFixed(0)}`);
  }
  const pre = document.createElement("pre");
  pre.textContent = lines.join("\n");
  pre.style.cssText = "font:11px/1.35 monospace;white-space:pre;margin:8px;color:#000;background:#fff";
  document.body.replaceChildren(pre);
  document.body.style.background = "#fff";
})();
