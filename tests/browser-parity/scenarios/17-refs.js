// Ref identity: a ref names one DOM node for the node's life. It survives a
// name change and moves, is never reused, fails fast once the node is gone,
// and never rebinds to another element.
// oracle: skip (ref identity is cmux-defined)
await page.goto(`${PRIMARY}/`);
await page.evaluate(() => {
  document.body.innerHTML = '<ul id=L><li><button id=a>Alpha</button></li><li><button id=b>Beta</button></li></ul><button id=out onclick="this.textContent=\'Out clicked\'">Out</button>';
});
const s1 = await snapshot({ interactive: true });
emitCmux("s1", s1.tree);
await page.evaluate(() => {
  document.getElementById("b").textContent = "Beta renamed";
  document.getElementById("L").insertAdjacentHTML("afterbegin", "<li><button>Zero</button></li>");
  document.getElementById("a").remove();
});
const s2 = await snapshot({ interactive: true });
emitCmux("s2", s2.tree);
emitCmux("s2-printed", String(s2));
const stale = async (ref) => {
  try {
    await page.locator(ref).click({ timeout: 2000 });
    return "clicked";
  } catch (e) {
    return e.message;
  }
};
emitCmux("removed", await stale("e1"));
emitCmux("unknown", await stale("e99"));
emitCmux("unknown-frame", await stale("f9e1"));
await page.evaluate(() => document.getElementById("L").append(document.getElementById("out")));
await page.locator("e3").click();
emitCmux("moved-still-works", await page.locator("#out").textContent());
emitCmux("renamed-still-works", await page.ref("e2").textContent());
await page.evaluate(() => { document.getElementById("L").insertAdjacentHTML("beforeend", "<li><button>New</button></li>"); });
emitCmux("never-reused", (await snapshot({ interactive: true })).tree.match(/button "New" \[ref=(\w+)\]/)[1]);
emitCmux("scoped", (await snapshot("e2")).tree);
emitCmux("not-invalidated-by-scope", await page.locator("e3").textContent());
try {
  page.ref("button");
  emitCmux("ref-validates", "no error");
} catch (e) {
  emitCmux("ref-validates", e.message);
}
emitCmux("is-visible-stale", await page.locator("e1").isVisible());
await page.goto(`${PRIMARY}/`);
emitCmux("after-navigation", await stale("e2"));
emitCmux("new-document-continues", (await snapshot({ interactive: true })).tree.match(/\[ref=(e\d+)\]/)[1]);
