// Page-read budget (classic page-read-budget items, cx-2y2): reads the
// snapshot walk does beside its tree walk stay within the snapshot's budget
// on hostile pages, and a snapshot that stops there says so.
// oracle: skip (snapshot budgets and cut notes are cmux-defined)
// ---- cell session=budget cmux-only
// A table is judged layout or data by a sample of its first 50 rows: a
// row past the sample with another length does not make a data table a
// layout table (classic TABLE_SAMPLE).
await page.setViewportSize({ width: 1280, height: 800 });
await page.goto(`${PRIMARY}/index.html`);
await page.evaluate(() => {
  const rows = [];
  for (let i = 0; i < 60; i++) rows.push(i === 55 ? "<tr><td>a</td><td>b</td><td>c</td></tr>" : `<tr><td>r${i}</td><td>v${i}</td></tr>`);
  document.body.innerHTML = `<table id="t">${rows.join("")}</table>`;
});
const table = (await snapshot({ maxChars: Infinity })).tree;
emitCmux("table-sample-data-rows", table.split("\n").filter((l) => /^\s*- row: "r\d+ \| v\d+"$/.test(l)).length);

// ---- cell session=budget cmux-only
// Offscreen interactive elements are counted within the snapshot's node
// budget; past it the count is a lower bound ("at least").
await page.evaluate(() => {
  const far = Array.from({ length: 3000 }, (_, i) => `<button>Far ${i}</button>`).join("");
  document.body.innerHTML = `<button>Near</button><div style="position:absolute;top:20000px">${far}</div>`;
});
const lineOf = (tree, re) => (tree.split("\n").find((l) => re.test(l)) || "").replace(/[\d,]+/g, "N");
const small = (await snapshot({ viewport: true, _maxNodes: 500 })).tree;
emitCmux("offscreen-lower-bound", lineOf(small, /interactive elements outside the viewport/));
const whole = (await snapshot({ viewport: true })).tree;
emitCmux("offscreen-exact", (whole.split("\n").find((l) => /interactive elements outside the viewport/.test(l)) || "").replace(/^# (\d+) .*/, "$1"));

// ---- cell session=budget cmux-only
// A zero-size link's visible-box check charges each node it looks at.
await page.evaluate(() => {
  const spans = "<span></span>".repeat(5000);
  document.body.innerHTML = `<a href="#x" style="display:inline-block;width:0;height:0;overflow:visible">${spans}</a><button>After</button>`;
});
const box = (await snapshot({ _maxNodes: 2000, maxChars: Infinity })).tree;
emitCmux("visible-box-charged", { after: box.includes('button "After"'), cut: /stopped after [\d,]+ nodes/.test(box) });

// ---- cell session=budget cmux-only
// A link URL longer than the size budget has left is cut as written, never
// resolved or parsed (no offsite summary); generated content, placeholders,
// option text and editable text past the budget are cut, and the snapshot
// says it stopped on its size budget.
await page.evaluate(() => {
  const long = "https://elsewhere.example/" + "p".repeat(20000);
  document.body.innerHTML = `<a href="${long}">Long</a>`;
});
const url = (await snapshot({ _maxSize: 5000, maxChars: Infinity })).tree;
const link = url.split("\n").find((l) => l.includes('link "Long"')) || "";
emitCmux("long-url", { url: /\[url=/.test(link), cut: /stopped after [\d,]+ characters/.test(url) });
// Each value is the first one past the budget in its own snapshot.
const bigCut = async (body) => {
  await page.evaluate((body) => {
    const big = "q".repeat(200000);
    document.body.innerHTML = body.replace(/BIG/g, big) + "<button>Tail</button>";
  }, body);
  const tree = (await snapshot({ _maxSize: 5000, maxChars: Infinity })).tree;
  return /stopped after [\d,]+ characters/.test(tree) && !tree.includes('button "Tail"') && tree.length < 20000;
};
await page.evaluate(() => {
  const style = document.createElement("style");
  style.textContent = `#gen::before { content: "${"q".repeat(200000)}"; }`;
  document.head.appendChild(style);
});
emitCmux("big-values-cut", {
  generated: await bigCut('<p id="gen">Generated</p>'),
  // Named by aria-label, so the placeholder read is the one that cuts.
  placeholder: await bigCut('<input aria-label="x" placeholder="BIG">'),
  // A list box has no value, so the option read is the one that cuts.
  option: await bigCut('<select size="2"><option label="BIG">one</option></select>'),
  editable: await bigCut('<div contenteditable="true">BIG</div>'),
});

// ---- cell session=budget cmux-only
// A name reads its sources within bounds charged to the snapshot: 1,000
// buttons named by one shared 50,000-node label stop at the node budget
// at once instead of reading the label 1,000 times whole.
await page.evaluate(() => {
  const words = "<span>w</span>".repeat(50000);
  const buttons = Array.from({ length: 1000 }, (_, i) => `<button aria-labelledby="shared">B${i}</button>`).join("");
  document.body.innerHTML = `<div id="shared" hidden>${words}</div>${buttons}`;
});
const namesStarted = Date.now();
const names = (await snapshot({ maxChars: Infinity })).tree;
emitCmux("shared-label-names", { cut: /stopped after [\d,]+ nodes/.test(names), fast: Date.now() - namesStarted < 15000 });

// ---- cell session=budget cmux-only
// Locator string reads, allTextContents and page.content read within the
// page-read budget (2,000,000 characters): a value past it ends with "…"
// where it stopped; sensitive field values still read as the marker.
await page.evaluate(() => {
  const big = "t".repeat(3000000);
  document.body.innerHTML = `<div id="big">${big}</div><p class="p">one</p><p class="p">${big}</p><p class="p">three</p><input id="pw" type="password" value="hunter2secret">`;
});
const text = await page.locator("#big").textContent();
emitCmux("locator-read-cut", { short: text.length <= 2000001, cut: text.endsWith("…") });
const inner = await page.locator("#big").innerText();
emitCmux("locator-inner-cut", { short: inner.length <= 2000001, cut: inner.endsWith("…") });
const all = await page.locator("p.p").allTextContents();
emitCmux("all-text-cut", { first: all[0], secondCut: all[1].endsWith("…") && all[1].length <= 2000001, third: all[2] });
const html = await page.content();
emitCmux("content-cut", { short: html.length <= 2000001, cut: html.endsWith("…") });
emitCmux("password-read", { value: await page.locator("#pw").inputValue(), attribute: await page.locator("#pw").getAttribute("value") });
// A short secret (under 4 characters) inside HTML results reads as the
// marker in its value attribute.
await page.evaluate(() => (document.body.innerHTML = '<div id="wrap"><input type="password" value="ab1"></div>'));
emitCmux("short-secret-html", (await page.locator("#wrap").innerHTML()).includes('value="ab1"') ? "leaked" : "masked");
