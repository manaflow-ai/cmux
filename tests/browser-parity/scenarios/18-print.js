// The last expression's value prints (awaited when it is a promise);
// undefined prints nothing; snapshots print their tree or diff; images
// print as a file path; display() and console.log format the same way.
// oracle: skip (printing is cmux-defined)
// ---- cell session=p capture
1 + 1
// ---- cell session=p capture
const x = { a: 1, b: [1, 2, "s"], c: null, nested: { deep: true } };
// ---- cell session=p capture
x
// ---- cell session=p capture
"plain string"
// ---- cell session=p capture
Promise.resolve(42)
// ---- cell session=p capture
undefined
// ---- cell session=p capture
await page.goto(`${PRIMARY}/aria.html`); snapshot({ interactive: true })
// ---- cell session=p capture
await page.evaluate(() => document.querySelector("h1").textContent = "Renamed"); snapshot({ interactive: true })
// ---- cell session=p capture
snapshot()
// ---- cell session=p capture
await page.evaluate(() => document.querySelector("h1").textContent = "Renamed again"); snapshot()
// ---- cell session=p capture
screenshot()
// ---- cell session=p capture
display({ shown: true }); display(await screenshot(page.locator("h1"))); console.log("log", [1, 2], { k: "v" });
// ---- cell session=p capture
page.url()
// ---- cell session=p capture
new Map([["k", 1]])
// ---- cell session=p capture
await page.consoleMessages()
