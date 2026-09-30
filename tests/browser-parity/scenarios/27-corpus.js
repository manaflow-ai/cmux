// Real-site corpus (fixtures/corpus, frozen by lib/corpus.mjs): on each page
// the snapshot must hold every interactive element of Chrome's Playwright AI
// snapshot with the same role and name (recall), print no text Chrome does
// not render (leaks), and stay within 10% of the size of Aside's snapshot of
// the same page (Aside drops some visible text cmux keeps, such as card
// descriptions). Recall is judged in the engine that renders cmux: each
// recorded element is found by its path and fixtures/corpus/gt.js, which is
// independent of the page agent, decides whether a user can see it here; an
// element Playwright gave no ref (no visible box in Chrome) is not required.
// Exact byte counts are printed, not compared.
// oracle: skip (compares cmux snapshots against Chrome records made by lib/corpus.mjs)
// ---- cell session=corpus
const squash = (s) => String(s).replace(/[\s\u200b-\u200d\u2060\ufeff]+/g, "").toLowerCase();
const aside = await (await fetch(`${PRIMARY}/corpus/aside-sizes.json`)).json();
globalThis.corpusCheck = async (name) => {
  const oracle = await (await fetch(`${PRIMARY}/corpus/${name}.oracle.json`)).json();
  // The Chrome records were made at 1280x800; a tab shown in a pane would
  // otherwise render at the pane's size.
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto(`${PRIMARY}/corpus/${name}.html`);
  const tree = (await snapshot()).tree;
  const gtSource = await (await fetch(`${PRIMARY}/corpus/gt.js`)).text();
  const shownHere = await page.evaluate(({ src, paths }) => {
    const gt = (0, eval)(src + "; ({ shown, byPath })");
    return paths.map((p) => (p ? gt.shown(gt.byPath(p)) : null));
  }, { src: gtSource, paths: oracle.interactive.map((w) => w.path || null) });
  const entries = [];
  const texts = [];
  for (const line of tree.split("\n")) {
    const head = /^(\s*)- ([\w-]+)(?: "((?:[^"\\]|\\.)*)")?/.exec(line);
    if (!head) continue;
    const value = /: "((?:[^"\\]|\\.)*)"$/.exec(line);
    const name = head[3] ? JSON.parse(`"${head[3]}"`) : "";
    const text = value ? JSON.parse(`"${value[1]}"`) : "";
    entries.push({ depth: head[1].length, role: head[2], name: squash(name), own: squash(name || text), text: squash(text), used: false });
    texts.push(name, text);
  }
  // An unnamed element is known by its content: its text and its descendants'.
  entries.forEach((e, i) => {
    let content = e.text;
    for (let j = i + 1; j < entries.length && entries[j].depth > e.depth; j++) content += entries[j].own;
    e.content = content;
  });
  // Printed names longer than the limit end in "…"; the rest must follow in order.
  const sameText = (printed, full) => {
    if (printed === full) return true;
    if (!printed.includes("…")) return false;
    const pieces = printed.split("…");
    if (!full.startsWith(pieces[0])) return false;
    let at = pieces[0].length;
    for (const piece of pieces.slice(1)) {
      const i = full.indexOf(piece, at);
      if (i < 0) return false;
      at = i + piece.length;
    }
    return !pieces[pieces.length - 1] || full.endsWith(pieces[pieces.length - 1]);
  };
  const missing = [];
  let notShownHere = 0;
  oracle.interactive.forEach((want, i) => {
    if (want.boxless) return;
    if (shownHere[i] === false) {
      notShownHere++;
      return;
    }
    const n = squash(want.name);
    const hit = entries.find((e) => !e.used && e.role === want.role &&
      (sameText(e.name, n) || (!e.name && sameText(e.content, n))));
    if (hit) hit.used = true;
    else missing.push(`${want.role} "${want.name}"`);
  });
  const shown = squash(texts.join("\n"));
  const leaks = oracle.hidden.filter((t) => shown.includes(squash(t)));
  const bytes = Buffer.byteLength(tree);
  console.log(`${name}: ${notShownHere} recorded elements not shown in this engine; cmux ${bytes} bytes, Aside ${aside[name]} bytes, Chrome AI snapshot ${oracle.chromeAiSnapshotBytes} bytes; ${oracle.interactive.length} interactive`);
  return { missing, leaks, withinAside: bytes <= 1.1 * aside[name] };
};
// ---- cell session=corpus
for (const name of ["wikipedia", "hackernews", "github"]) {
  const r = await corpusCheck(name);
  emitCmux(`${name}:missing`, r.missing);
  emitCmux(`${name}:leaks`, r.leaks);
  emitCmux(`${name}:within-aside-10pct`, r.withinAside);
}
// ---- cell session=corpus
for (const name of ["mdn", "mdn-iframe", "npr"]) {
  const r = await corpusCheck(name);
  emitCmux(`${name}:missing`, r.missing);
  emitCmux(`${name}:leaks`, r.leaks);
  emitCmux(`${name}:within-aside-10pct`, r.withinAside);
}
// ---- cell session=corpus
for (const name of ["bbc", "books", "vercel"]) {
  const r = await corpusCheck(name);
  emitCmux(`${name}:missing`, r.missing);
  emitCmux(`${name}:leaks`, r.leaks);
  emitCmux(`${name}:within-aside-10pct`, r.withinAside);
}
