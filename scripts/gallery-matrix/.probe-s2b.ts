import { chromium } from "playwright";
const [variant, entry] = [process.argv[2], process.argv[3]];
const b = await chromium.launch({ channel: "chrome" });
const p = await b.newPage({ viewport: { width: 760, height: 600 } });
await p.addInitScript(() => {
  const log: string[] = []; (window as any).__log = log;
  const ids = new WeakMap<Element, number>(); let next = 1; let n = 0;
  const tick = () => {
    n++;
    const parts = [...document.querySelectorAll(".ui-glass, .acpmux-composer-bar")].map((e) => {
      if (!ids.has(e)) ids.set(e, next++);
      const r = e.getBoundingClientRect(); const cs = getComputedStyle(e);
      return `#${ids.get(e)}${e.classList.contains("ui-glass") ? "g" : "b"}@${Math.round(r.top)}h${Math.round(r.height)}${cs.visibility === "hidden" ? "H" : ""}`;
    });
    const gl = ((window as any).cmuxGalleryLog ?? []).length;
    log.push(`f${n} c${gl} ${parts.join(" ")}`);
    if (n < 300) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
});
const q = new URLSearchParams({ entry, variant, locale: "en", theme: "Apple System Colors", colorScheme: "dark", frame: "component", width: "760", height: "600" });
await p.goto(`http://127.0.0.1:8765/frame.html?${q}`);
await p.waitForTimeout(4000);
const log: string[] = await p.evaluate(() => (window as any).__log);
let prev = "";
for (const l of log) { const t = l.split(" ").slice(2).join(" "); if (t !== prev) { console.log(l); prev = t; } }
await b.close();
