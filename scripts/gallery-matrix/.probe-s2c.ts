import { chromium } from "playwright";
const [variant, entry] = [process.argv[2], process.argv[3]];
const b = await chromium.launch({ channel: "chrome" });
const p = await b.newPage({ viewport: { width: 760, height: 600 } });
await p.addInitScript(() => {
  const log: string[] = []; (window as any).__log = log; let n = 0;
  const tick = () => {
    n++;
    const bar = document.querySelector("form.acpmux-composer .acpmux-composer-bar") ?? document.querySelector("form.acpmux-composer");
    if (bar) {
      const chain: string[] = [];
      for (let e: Element | null = bar; e; e = e.parentElement) {
        const cs = getComputedStyle(e);
        chain.push(`${e.tagName.toLowerCase()}.${String(e.className).split(" ").slice(0,2).join(".")}[${cs.visibility[0]}${cs.opacity}${e.hasAttribute("hidden")?"Hd":""}${e.hasAttribute("inert")?"I":""}${cs.transitionProperty!=="all"||cs.transitionDuration!=="0s"?" t="+cs.transitionProperty+"/"+cs.transitionDuration:""}]`);
      }
      log.push(`f${n} ${chain.join(" < ")}`);
    }
    if (n < 80) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
});
const q = new URLSearchParams({ entry, variant, locale: "en", theme: "Apple System Colors", colorScheme: "dark", frame: "component", width: "760", height: "600" });
await p.goto(`http://127.0.0.1:8765/frame.html?${q}`);
await p.waitForTimeout(3000);
const log: string[] = await p.evaluate(() => (window as any).__log);
let prev = ""; for (const l of log) { const t = l.split(" ").slice(1).join(" "); if (t !== prev) { console.log(l); prev = t; } }
await b.close();
