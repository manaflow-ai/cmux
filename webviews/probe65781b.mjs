// https://github.com/manaflow-ai/cmux/issues/65781: a range drag whose release never reaches Chromium
// (the page window lost the mouseup), then moves with no button. Which page-side recovery ends it?
import { chromium } from "playwright";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 400, height: 200 } });
const cdp = await page.context().newCDPSession(page);
const send = (type, x, buttons, button = "none") =>
  cdp.send("Input.dispatchMouseEvent", { type, x, y: 28, button, buttons, clickCount: type === "mouseMoved" ? 0 : 1 });
const recoveries = {
  none: "",
  syntheticMouseup: "r.dispatchEvent(new MouseEvent('mouseup', {bubbles: true, button: 0}));",
  blur: "r.blur();",
  disableToggle: "r.disabled = true; queueMicrotask(() => (r.disabled = false));",
  remount: "const n = r.cloneNode(); n.value = r.value; r.replaceWith(n); window.r = n;",
};
for (const [name, recover] of Object.entries(recoveries)) {
  for (const capture of [false, true]) {
    await page.setContent(`<body style="margin:0"><input id=r type=range min=0 max=100 value=50
      style="position:absolute;left:20px;top:20px;width:300px;margin:0"><script>
      window.r = document.getElementById('r'); window.log = []; window.recovered = false;
      ${capture ? "r.addEventListener('pointerdown', e => r.setPointerCapture(e.pointerId));" : ""}
      document.addEventListener('pointermove', e => { if (e.buttons === 0 && !recovered && log.includes('down')) { recovered = true; ${recover} } }, true);
      r.addEventListener('pointerdown', () => log.push('down'));
      for (const t of ['pointerup','lostpointercapture','change','mouseup']) document.addEventListener(t, () => log.push(t), true);
      </script></body>`);
    await send("mouseMoved", 100, 0);
    await send("mousePressed", 100, 1, "left");
    for (const x of [130, 160, 190]) await send("mouseMoved", x, 1, "left");
    // No mouseReleased: the release never reaches the page.
    const afterDrag = Number(await page.evaluate(() => window.r.value));
    const tx = 20 + afterDrag * 3;
    for (let dx = 0; dx <= 60; dx += 6) await send("mouseMoved", tx + dx, 0);
    const afterHover = await page.evaluate(() => window.r.value);
    console.log(`PROBE2 recovery=${name} capture=${capture} afterDrag=${afterDrag} afterHoverNoButton=${afterHover} events=${await page.evaluate(() => log.join(","))}`);
  }
}
await browser.close();
