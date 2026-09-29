// Visual outputs: raw screenshot, annotated screenshot, element screenshot, PDF.
await openTab(`${PRIMARY}/`);
const png = await page.screenshot();
emit("screenshot", { isBuffer: Buffer.isBuffer(png), png: png.subarray(1, 4).toString() });
const ann = await annotatedScreenshot(page);
emit("annotated-keys", Object.keys(ann).sort());
emit("annotated-png", Buffer.from(ann.base64Image, "base64").subarray(1, 4).toString());
const el = await page.locator("form").screenshot();
emit("element-shot", el.subarray(1, 4).toString());
await fs.mkdir("./artifacts", { recursive: true });
await page.pdf({ path: "./artifacts/p.pdf", format: "A4" });
emit("pdf-magic", String(await fs.readFile("./artifacts/p.pdf")).slice(0, 5));
