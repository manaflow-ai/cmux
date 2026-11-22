// Large pages (fixtures/stress): locators, selects, shadow roots, frames and
// virtual lists behave as in Playwright at scale; a printed snapshot fits the
// print budget while .tree stays complete, and a ref in the condensed-away
// part still resolves.
// ---- cell session=stress
const stress = (kind, n, extra = "") => `${PRIMARY}/stress/stress.html?kind=${kind}&n=${n}${extra}`;
await page.goto(stress("list", 5000));
emit("list-count", await page.locator("li").count());
emit("list-last", await page.getByRole("link", { name: "Item 4999", exact: true }).textContent());
await page.goto(stress("table", 10000));
emit("table-rows", await page.getByRole("row").count());
emit("table-cell", await page.getByRole("row", { name: /^9990 / }).getByRole("link").textContent());
await page.goto(stress("select", 5000));
emit("select-option", await page.locator("#pick").selectOption("4999"));
emit("select-value", await page.locator("#pick").inputValue());
emit("select-many", await page.locator("#many").selectOption(["3", "4998"]));
await page.goto(stress("shadow", 2000));
emit("shadow-last", await page.getByRole("button", { name: "Shadow 1999", exact: true }).textContent());
emit("shadow-count", await page.getByRole("button").count());
await page.goto(stress("iframes", 30, `&peer=${encodeURIComponent(PEER)}`));
await page.waitForLoadState("load");
emit("frame-cross", await page.frameLocator('iframe[title="cross 28"]').getByRole("button").textContent());
emit("frame-nested", await page.frameLocator('iframe[title="nested 29"]').frameLocator("iframe").getByRole("button").textContent());
await page.goto(stress("virtual", 100000));
await page.locator("#viewport").evaluate((el) => (el.scrollTop = 30 * 5000));
await page.getByRole("link", { name: "Row 5000", exact: true }).waitFor();
emit("virtual-row", await page.getByRole("link", { name: "Row 5000", exact: true }).textContent());

// ---- cell session=stress cmux-only
await page.goto(stress("list", 5000));
const s = await snapshot();
const printed = String(s);
emitCmux("list-printed-within-budget", printed.length <= 20000);
emitCmux("list-tree-complete", (s.tree.match(/link "Item \d+"/g) || []).length);
emitCmux("list-condensed-note", /^# condensed to [\d,]+ of [\d,]+ characters/.test(printed.split("\n").pop()));
emitCmux("list-cut-line", printed.split("\n").find((l) => /- … [\d,]+ more listitem/.test(l)).trim().replace(/[\d,]+/g, "N"));
const hidden = /link "Item 4000" \[ref=(\w+)\]/.exec(s.tree)[1];
emitCmux("list-cut-ref-resolves", printed.includes(`[ref=${hidden}]`) ? "printed" : await page.locator(hidden).textContent());
// A new scope has no previous snapshot, so the whole tree prints.
emitCmux("list-all", String(await snapshot(page.locator("nav"), { maxChars: Infinity })).length > 100000);
await page.goto(stress("select", 5000));
emitCmux("select-inline", (await snapshot()).tree.split("\n").find((l) => l.includes('combobox "Pick"')));

// ---- cell session=stress cmux-only
// A page nested deeper than the walk reads (1,000 elements over all
// stitched frames, as in classic, on WebKit and Chromium alike): the deeper
// part prints as one generic with a ref and the cut note, the page after it
// still reads, a snapshot of that ref reads on, and page.markdown ends with
// its note. showHidden: WebKit lays out no element this deep, so only the
// walk itself (not rendering) decides what is read on both engines.
const deepOpts = { showHidden: true, maxChars: Infinity };
const cutOf = (tree) => {
  const line = tree.split("\n").find((l) => l.includes("[not read: nested deeper"));
  return line ? line.trim().replace(/ref=f?\d*e\d+/, "ref=eN") : null;
};
const addLast = () => page.evaluate(() => document.getElementById("root").insertAdjacentHTML("afterend", "<button>Last</button>"));
await page.goto(stress("deep", 1200));
await addLast();
const deep = await snapshot(deepOpts);
emitCmux("deep-cut-line", cutOf(deep.tree));
emitCmux("deep-cut-hides-deepest", !/Deepest/.test(deep.tree));
emitCmux("deep-reads-after-the-cut", /button "Last"/.test(deep.tree));
const cutRef = (/\[ref=(e\d+)\] \[not read: nested deeper/.exec(deep.tree) || [])[1];
emitCmux("deep-cut-ref-reads-on", !!cutRef && /button "Deepest"/.test((await snapshot(cutRef, deepOpts)).tree));
const deepMarkdown = await page.markdown();
emitCmux("deep-markdown-note", deepMarkdown.trim().split("\n").pop());
emitCmux("deep-markdown-hides-bottom", !deepMarkdown.includes("bottom text"));
emitCmux("deep-markdown-reads-after-the-cut", deepMarkdown.includes("Last"));

// ---- cell session=stress cmux-only
// Every level a named group: the stitched tree itself is 1,000 levels deep,
// and stitching, shaping, condensing and printing it must not recurse that
// deep (the host VM's stack holds about 1,300 calls).
await page.goto(stress("deep", 1200, "&every=1"));
const named = await snapshot({ showHidden: true });
emitCmux("deep-named-cut-line", cutOf(named.tree));
emitCmux("deep-named-levels", (named.tree.match(/group "level \d+"/g) || []).length);
emitCmux("deep-named-printed-within-budget", String(named).length <= 20000);
emitCmux("deep-named-interactive-hides-deepest", !/Deepest/.test((await snapshot({ showHidden: true, interactive: true })).tree));

// ---- cell session=stress cmux-only
// Iframes nested inside each other, 400 levels each: the bound holds for
// the stitched tree, not per frame (classic r16), so the third frame is
// not read and the cut says so.
await page.goto(stress("deep", 0));
await page.evaluate(() => {
  let doc = document;
  let at = document.getElementById("root");
  for (let f = 0; f < 3; f++) {
    for (let i = 0; i < 400; i++) (at = at.appendChild(doc.createElement("div"))).setAttribute("role", "group"), at.setAttribute("aria-label", "g");
    const frame = at.appendChild(doc.createElement("iframe"));
    doc = frame.contentDocument;
    doc.open();
    doc.write(`<!doctype html><body><p>frame ${f}</p></body>`);
    doc.close();
    at = doc.body;
  }
  at.appendChild(doc.createElement("p")).textContent = "deepest";
});
await addLast();
const framed = (await snapshot(deepOpts)).tree;
emitCmux("frames-cut-line", cutOf(framed));
emitCmux("frames-first-read", /frame 0/.test(framed));
emitCmux("frames-third-not-read", !/frame 2|deepest/.test(framed));
emitCmux("frames-reads-after-the-cut", /button "Last"/.test(framed));
