// page.markdown on the frozen real-site corpus (fixtures/corpus): every link
// Chrome lists that this engine shows keeps its text, no text Chrome does not
// render appears, no HTML or frame placeholder is left outside code, and
// every line of { main: true } is a line of the page (all of it when the page
// has no <main> or single <article> and no landmarks to leave out).
// oracle: skip (cmux-defined Markdown checked against Chrome records made by lib/corpus.mjs)
// ---- cell session=md
// Whitespace and Markdown marks (escapes, code, emphasis) do not count.
const squash = (s) => String(s).replace(/[\s\u200b-\u200d\u2060\ufeff\\`*]+/g, "").toLowerCase();
globalThis.markdownCheck = async (name) => {
  const oracle = await (await fetch(`${PRIMARY}/corpus/${name}.oracle.json`)).json();
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto(`${PRIMARY}/corpus/${name}.html`);
  const md = await page.markdown();
  const main = await page.markdown({ main: true });
  const gtSource = await (await fetch(`${PRIMARY}/corpus/gt.js`)).text();
  const seen = await page.evaluate(({ src, paths }) => {
    const gt = (0, eval)(src + "; ({ shown, byPath })");
    return paths.map((p) => {
      const el = p ? gt.byPath(p) : null;
      return el ? { shown: gt.shown(el), text: el.innerText || el.textContent || "" } : { shown: null, text: null };
    });
  }, { src: gtSource, paths: oracle.interactive.map((w) => w.path || null) });
  const flat = squash(md);
  let links = 0;
  const missing = [];
  oracle.interactive.forEach((want, i) => {
    if (want.role !== "link" || want.boxless || seen[i].shown === false) return;
    const own = seen[i].text && squash(seen[i].text);
    if (!own || own.length < 3 || squash(want.name) !== own) return;
    links++;
    if (!flat.includes(own)) missing.push(want.name);
  });
  const leaks = oracle.hidden.filter((t) => squash(t).length > 3 && flat.includes(squash(t)));
  console.log(`${name}: ${md.length} chars, main ${main.length}; ${links} text links, ${missing.length} missing`);
  return { missing, leaks, mainIsPart: main.length <= md.length && main.split("\n").every((l) => md.includes(l.trim())), noMarkup: !/\u0000/.test(md) && !/<\/?(div|span|script)\b/.test(md.replace(/```[\s\S]*?```|`[^`\n]*`/g, "")) };
};
// ---- cell session=md
for (const name of ["wikipedia", "hackernews", "github", "mdn", "mdn-iframe", "npr", "bbc", "books", "vercel"]) {
  const r = await markdownCheck(name);
  emitCmux(`${name}:missing-links`, r.missing);
  emitCmux(`${name}:leaks`, r.leaks);
  emitCmux(`${name}:main-is-a-part`, r.mainIsPart);
  emitCmux(`${name}:no-markup`, r.noMarkup);
}
