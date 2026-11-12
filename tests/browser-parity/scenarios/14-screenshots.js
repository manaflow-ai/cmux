// Visual outputs: screenshot() images of the viewport, full page, a locator
// and a ref; annotated screenshots; page.screenshot() bytes; PDF.
await page.goto(`${PRIMARY}/`);
const shot = await screenshot();
emit("viewport", { type: shot.type, width: shot.width, height: shot.height });
const full = await screenshot({ fullPage: true });
emit("full-page-taller", full.height > shot.height);
const form = await screenshot(page.locator("form"));
emit("locator-smaller", form.width < shot.width && form.height < shot.height);
const s = await snapshot();
const button = s.tree.match(/button "Create account" \[ref=(\w+)\]/)[1];
const byRef = await screenshot(button);
emit("ref-matches-locator", Math.abs(byRef.width - (await page.locator("#submit").boundingBox()).width) <= 1);
const jpeg = await screenshot({ type: "jpeg", quality: 60 });
emit("jpeg", jpeg.type);
const png = await page.screenshot();
emit("buffer", { isBuffer: Buffer.isBuffer(png), magic: png.subarray(1, 4).toString() });
const annotated = await screenshot({ annotate: true });
emitCmux("annotated-size", [annotated.width, annotated.height]);
emitCmux("annotated-differs", !annotated.buffer.equals(shot.buffer));
const again = await screenshot();
emitCmux("annotations-removed", again.buffer.equals(shot.buffer));
emitCmux("no-overlay-in-dom", await page.evaluate(() => document.querySelectorAll("cmux-annotations").length));
fs.mkdirSync("./artifacts", { recursive: true });
await page.pdf({ path: "./artifacts/p.pdf", format: "A4" });
emit("pdf-magic", fs.readFileSync("./artifacts/p.pdf").subarray(0, 5).toString());
await screenshot({ path: "./artifacts/s.png" });
emit("screenshot-path", fs.readFileSync("./artifacts/s.png").subarray(1, 4).toString());
