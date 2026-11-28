// Plain-http pages outside localhost load without a prompt: goto, a new tab,
// and a link click. cmux gates such URLs behind a prompt for people; a REPL
// tab has nobody to answer it, so the prompt would hang the call.
if (!INSECURE) throw new Error("lvh.me does not resolve to 127.0.0.1; the insecure-http fixture needs it");
await page.goto(`${INSECURE}/aria.html`);
emit("goto-title", await page.title());
const other = await tabs.open(`${INSECURE}/dynamic.html`);
emit("open-title", await other.title());
await tabs.use(other);
await page.goto(`${PRIMARY}/index.html`);
await page.evaluate((href) => {
  const a = document.createElement("a");
  a.id = "to-insecure";
  a.href = href;
  a.textContent = "Insecure link";
  document.body.prepend(a);
}, `${INSECURE}/files.html`);
await Promise.all([page.waitForURL(/files\.html$/), page.locator("#to-insecure").click()]);
emit("link-title", await page.title());
