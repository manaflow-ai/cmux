// Shoot every chat-live-gap variant twice as-is and once with animations frozen. Usage: bun shoot.mjs OUTDIR
import { chromium } from "playwright";
const out = process.argv[2];
const looks = ["before", "jumps", "slot8", "shipped"].flatMap((l) => [`${l}-run`, `${l}-reply`]);
const browser = await chromium.launch();
for (const v of looks) {
  for (const mode of ["raw1", "raw2", "frozen"]) {
    const page = await browser.newPage({ viewport: { width: 760, height: 420 } });
    const q = new URLSearchParams({ entry: "agent-pane.chat-live-gap", variant: v, colorScheme: "dark", width: "narrow", frame: "component" });
    await page.goto(`http://127.0.0.1:4391/gallery/frame.html?${q}`, { waitUntil: "domcontentloaded" });
    if (mode === "frozen") await page.addStyleTag({ content: "*,*::before,*::after{animation:none!important;transition:none!important}" });
    await page.waitForTimeout(mode === "raw2" ? 4700 : 4000);
    await page.screenshot({ path: `${out}/${v}.${mode}.png` });
    await page.close();
  }
}
await browser.close();
