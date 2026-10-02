// The per-tab virtual clipboard: read/write from the REPL, and Meta+C,
// Meta+X and Meta+V in the page. The system clipboard is never used.
// oracle: skip (the virtual clipboard is cmux-defined)
await page.goto(`${PRIMARY}/input.html`);
await page.clipboard.writeText("clip text");
emitCmux("read-text", await page.clipboard.readText());
await page.locator("#clip").click();
await page.keyboard.press("Meta+v");
emitCmux("pasted", await page.locator("#clip").inputValue());
await page.locator("#keys").fill("copy me");
await page.locator("#keys").selectText();
await page.keyboard.press("Meta+c");
emitCmux("copied", await page.clipboard.readText());
await page.keyboard.press("Meta+x");
emitCmux("cut", [await page.clipboard.readText(), await page.locator("#keys").inputValue()]);
await page.clipboard.write([{ type: "text/plain", data: "via write" }]);
const items = await page.clipboard.read();
emitCmux("read-items", items.map((i) => [i.type, i.data.toString()]));
emitCmux("trusted-paste", await page.evaluate(() => window.__summary().filter((l) => /^(input) #clip/.test(l))));

// Copy and Cut run the page's own handlers: one that sets clipboardData and
// cancels decides what lands on the tab's clipboard, and cancelling a cut
// keeps the text.
await page.evaluate(() => {
  const keys = document.getElementById("keys");
  window.__clip = [];
  for (const type of ["copy", "cut"]) {
    keys.addEventListener(type, (e) => {
      window.__clip.push(type);
      const mode = keys.dataset.mode;
      if (mode === "custom") {
        e.clipboardData.setData("text/plain", `${type}: ${keys.value.slice(keys.selectionStart, keys.selectionEnd).toUpperCase()}`);
        e.clipboardData.setData("text/html", `<b>${type}</b>`);
        e.preventDefault();
      } else if (mode === "alert") {
        // A dialog in the handler must not hold the command: cmux answers
        // it as Playwright answers a dialog nobody handles.
        const answer = type === "copy" ? (alert(`${type} alert`), "alerted") : String(confirm(`${type} confirm`));
        e.clipboardData.setData("text/plain", `after ${type}: ${answer}`);
        e.preventDefault();
      }
    });
  }
});
// WebKit rewrites HTML it writes (inline styles), so match the element only.
const clipHtml = async (pattern) => (await page.clipboard.read()).some((i) => i.type === "text/html" && pattern.test(i.data.toString()));
await page.locator("#keys").fill("make it loud");
await page.evaluate(() => { document.getElementById("keys").dataset.mode = "custom"; });
await page.locator("#keys").selectText();
await page.keyboard.press("Meta+c");
emitCmux("custom-copy", [await page.clipboard.readText(), await clipHtml(/<b\b[^>]*>copy<\/b>/), await page.locator("#keys").inputValue()]);
await page.locator("#keys").selectText();
await page.keyboard.press("Meta+x");
emitCmux("custom-cut", [await page.clipboard.readText(), await clipHtml(/<b\b[^>]*>cut<\/b>/), await page.locator("#keys").inputValue()]);
// A plain cut removes the selection and fires the page's cut event.
await page.evaluate(() => { document.getElementById("keys").dataset.mode = ""; });
await page.locator("#keys").selectText();
await page.keyboard.press("Meta+x");
emitCmux("plain-cut", [await page.clipboard.readText(), await page.locator("#keys").inputValue()]);
emitCmux("clipboard-events", await page.evaluate(() => window.__clip));
// Dialogs from a Copy or Cut handler: dismissed at once, reported once at the
// top of the next snapshot and to "dialog" listeners, and never left open.
await page.locator("#keys").fill("ask first");
await page.evaluate(() => { document.getElementById("keys").dataset.mode = "alert"; });
await page.locator("#keys").selectText();
await page.keyboard.press("Meta+c");
const pendingAfterCopy = page.dialog() && page.dialog().type;
if (pendingAfterCopy) await page.dialog().dismiss();
const header = (await snapshot()).tree.split("\n").filter((l) => /^dialog/.test(l));
emitCmux("alert-copy", { pending: pendingAfterCopy, clipboard: await page.clipboard.readText(), header });
emitCmux("alert-copy-reported-once", (await snapshot()).tree.split("\n").filter((l) => /^dialog/.test(l)));
const seen = [];
page.on("dialog", (d) => {
  seen.push([d.type(), d.message()]);
  d.accept().catch((e) => seen.push(e.message));
});
await page.locator("#keys").selectText();
await page.keyboard.press("Meta+x");
await page.waitForTimeout(100);
emitCmux("confirm-cut-listener", { seen, clipboard: await page.clipboard.readText(), value: await page.locator("#keys").inputValue() });
// ---- cell
// A Copy the page has not finished within 5 s: cmux ends the tab's web
// content process, so nothing the page does later reaches a pasteboard.
// WebKit would otherwise write a late copy's data to the system clipboard,
// the one the terminal pastes from. This handler clears the selection
// before it returns, so a build without the fix writes nothing either;
// what differs is whether the page outlived the timeout.
await page.goto(`${PRIMARY}/input.html`);
await page.clipboard.writeText("before the late copy");
await page.evaluate(() => {
  const keys = document.getElementById("keys");
  keys.addEventListener("copy", () => {
    const end = Date.now() + 8000;
    while (Date.now() < end) {}
    keys.setSelectionRange(0, 0);
    keys.blur();
    getSelection().removeAllRanges();
  });
});
await page.locator("#keys").fill("never copied");
await page.locator("#keys").selectText();
let lateCopyCrashed = false;
page.on("crash", () => { lateCopyCrashed = true; });
const lateCopy = await page.keyboard.press("Meta+c").then(
  () => "finished",
  (e) => ({ code: e.code ?? null, endedWebContent: /ended the tab's web content process/.test(e.message) }),
);
for (let i = 0; i < 40 && !lateCopyCrashed; i++) await sleep(50);
await page.goto(`${PRIMARY}/input.html?after-late-copy`);
emitCmux("late-copy", { late: lateCopy, crashed: lateCopyCrashed, clipboard: await page.clipboard.readText(), reloaded: await page.locator("#keys").inputValue() });
// ---- cell cmux-only
// A tab a one-shot run keeps is the user's once the run ends.
const keptForClipboard = await tabs.open(`${PRIMARY}/input.html?clipboard-user-tab`);
await keptForClipboard.keep();
// ---- cell session=clipboard-user cmux-only
// Copy, Cut and Paste are refused in a user's tab: cmux contains a page
// that outlives the 5 s timeout by ending the tab's web content process,
// which it does only in tabs a session opened.
const clipboardUserRow = (await tabs.list()).find((t) => t.url.endsWith("?clipboard-user-tab"));
const clipboardUserTab = await tabs.use(clipboardUserRow.id);
await clipboardUserTab.locator("#keys").fill("the user's text");
await clipboardUserTab.locator("#keys").selectText();
const userTabShortcuts = [];
for (const key of ["Meta+c", "Meta+x", "Meta+v"]) {
  userTabShortcuts.push(await clipboardUserTab.keyboard.press(key).then(() => "ran", (e) => [e.code ?? null, /in a user's tab/.test(e.message)]));
}
emitCmux("user-tab-clipboard", { shortcuts: userTabShortcuts, value: await clipboardUserTab.locator("#keys").inputValue() });
await clipboardUserTab.close();
