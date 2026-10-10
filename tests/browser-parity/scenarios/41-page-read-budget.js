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

// ---- cell session=budget cmux-only
// page.markdown reads within the page-read budget (here lowered to 5,000
// characters) and ends with the note where it stopped; page text cannot
// spell an iframe placeholder; at most 100 iframes are read.
await page.evaluate(() => (document.body.innerHTML = `<p>${"m".repeat(20000)}</p><p>Markdown tail</p>`));
const md = await page.markdown({ _maxSize: 5000 });
emitCmux("markdown-cut", { short: md.length < 8000, note: /<!-- the page is too large to read whole: Markdown stopped after 5,000 characters/.test(md), tail: md.includes("Markdown tail") });
await page.evaluate(() => {
  document.body.innerHTML = '<p id="forge"></p><iframe srcdoc="<p>INNER FRAME</p>"></iframe>';
  document.getElementById("forge").textContent = "\u0000F0\u0000 and \u0000F1\u0000";
});
await page.waitForLoadState("load");
await page.frameLocator("iframe").locator("p").waitFor();
const forged = await page.markdown();
emitCmux("markdown-placeholder-forged", forged.split("INNER FRAME").length - 1);
await page.evaluate(() => (document.body.innerHTML = Array.from({ length: 105 }, (_, i) => `<iframe srcdoc="<p>F${i}</p>"></iframe>`).join("")));
await page.waitForLoadState("load");
await page.frameLocator("iframe").last().locator("p").waitFor();
const many = await page.markdown();
emitCmux("markdown-frames-cut", /Markdown stopped after 100 frames/.test(many));
await page.evaluate(() => (document.body.innerHTML = '<nav><p>Navigation words</p></nav><main><p>Main words</p></main>'));
const mainOnly = await page.markdown({ main: true });
emitCmux("markdown-main", { main: mainOnly.includes("Main words"), nav: mainOnly.includes("Navigation words") });

// ---- cell session=budget cmux-only
// searchText caps contexts at 1,000 characters a side and reads the text
// within the budget; extract reads values within it; storageState refuses
// a localStorage past it; tabs.content cuts a page's text at its share.
await page.evaluate(() => (document.body.innerHTML = `<p>${"s".repeat(5000)} needle ${"s".repeat(5000)}</p>`));
const found = await page.searchText("needle", { context: 5000 });
emitCmux("search-context-capped", found.matches.length === 1 && found.matches[0].context.length <= 2010);
await page.evaluate(() => (document.body.innerHTML = `<p class="x">${"e".repeat(1500000)}</p><p class="x">${"e".repeat(1500000)}</p><p class="x">last</p>`));
const extracted = await page.extract(["p.x"]);
emitCmux("extract-cut", { count: extracted.length, total: extracted.reduce((n, v) => n + (v ? v.length : 0), 0) <= 2000001 });
await page.evaluate(() => {
  localStorage.clear();
  localStorage.setItem("big", "l".repeat(2100000));
});
let storage;
try {
  await session.storageState({ urls: [PRIMARY] });
  storage = "saved";
} catch (e) {
  storage = /localStorage stopped after 2,000,000 characters/.test(String(e.message)) ? "refused-with-note" : String(e.message).slice(0, 200);
}
await page.evaluate(() => localStorage.clear());
emitCmux("storage-state-cut", storage);
const rows = await tabs.content([`${PRIMARY}/stress/stress.html?kind=text&n=3000000`], { format: "text" });
emitCmux("tabs-content-cut", { short: rows[0].content.length <= 2000001, note: /tabs\.content stopped after/.test(rows[0].truncated || "") });
// tabs.content's HTML is read like page.content: sensitive values masked.
const htmlRows = await tabs.content([`${PRIMARY}/states.html`], { format: "html" });
emitCmux("tabs-content-html-masked", { leaked: htmlRows[0].content.includes("hunter2"), masked: htmlRows[0].content.includes("********") });

// ---- cell session=budget cmux-only
// An action in a child frame finds the frame's <iframe> by the frame's
// place in window.frames (light DOM), or by a walk within the parent's node
// budget (an <iframe> in a shadow tree, which window.frames may not list).
await page.evaluate(() => {
  const button = (label) => `<button onclick="this.textContent='${label} clicked'">${label}</button>`;
  document.body.innerHTML = `<div style="height:1500px"></div><iframe id="light" srcdoc="${button("Light").replace(/"/g, "&quot;")}"></iframe><div id="host"></div>`;
  const root = document.getElementById("host").attachShadow({ mode: "open" });
  root.innerHTML = `<div style="height:1500px"></div><iframe id="shadowed" srcdoc="${button("Shadow").replace(/"/g, "&quot;")}"></iframe>`;
});
const lightButton = page.frameLocator("#light").getByRole("button");
const shadowButton = page.frameLocator("#shadowed").getByRole("button");
await lightButton.waitFor();
await shadowButton.waitFor();
await lightButton.click();
await shadowButton.click();
emitCmux("frame-clicks", [await lightButton.textContent(), await shadowButton.textContent()]);
