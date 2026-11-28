// A file chooser without a listener stays open: the snapshot shows it with
// the ref of its input, and page.fileChooser() answers it.
// oracle: skip (without a listener Playwright opens no chooser to hold)
await page.goto(`${PRIMARY}/files.html`);
await page.locator("#picker").click();
emitCmux("snapshot", (await snapshot()).tree);
const c = page.fileChooser();
emitCmux("multiple", c.multiple);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "parity-"));
fs.writeFileSync(path.join(dir, "held.txt"), "held file");
await c.setFiles(path.join(dir, "held.txt"));
await page.waitForFunction(() => document.getElementById("files").textContent.startsWith("hidden-file:"));
emitCmux("set", await page.locator("#files").textContent());
emitCmux("answered", page.fileChooser());
await page.locator("#many").click();
emitCmux("many-line", (await snapshot()).tree.split("\n")[2]);
emitCmux("many-multiple", page.fileChooser().multiple);
await page.fileChooser().cancel();
emitCmux("cancelled", page.fileChooser());
emitCmux("unchanged", await page.locator("#files").textContent());
try {
  await c.setFiles(path.join(dir, "held.txt"));
  emitCmux("answer-twice", "no error");
} catch (e) {
  emitCmux("answer-twice", e.message);
}
fs.rmSync(dir, { recursive: true, force: true });
