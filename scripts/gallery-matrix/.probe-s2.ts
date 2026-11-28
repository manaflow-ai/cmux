import { chromium } from "playwright";
const variant = process.argv[2] ?? "empty";
const entry = process.argv[3] ?? "agent-pane.new-tab";
const b = await chromium.launch({ channel: "chrome" });
const p = await b.newPage({ viewport: { width: 760, height: 600 } });
await p.addInitScript(() => {
  const log: string[] = [];
  (window as any).__log = log;
  let n = 0;
  const tick = () => {
    n++;
    const bar = document.querySelector(".acpmux-composer-bar");
    const scrolled = [...document.querySelectorAll("*")].filter((e) => (e as HTMLElement).scrollTop > 0).map((e) => `${e.tagName.toLowerCase()}.${String((e as HTMLElement).className).split(" ")[0]}=${(e as HTMLElement).scrollTop}`);
    if (bar) {
      const r = bar.getBoundingClientRect(); const gg=document.querySelector(".ui-glass") as HTMLElement|null; const cs=gg?getComputedStyle(gg):null; const vis=cs?`${cs.visibility}/${cs.opacity}/nt=${!!document.querySelector(".nt-screen")}`:"-";
      const chain: string[] = [];
      for (let e: Element | null = bar; e && chain.length < 12; e = e.parentElement) {
        const rr = e.getBoundingClientRect(); chain.push(`${e.tagName.toLowerCase()}.${String(e.className).split(" ")[0]}@${Math.round(rr.top)}h${Math.round(rr.height)}`);
      }
      const gl=((window as any).cmuxGalleryLog??[]).map((c:any)=>c.method).filter((m:string)=>/^(ready|newTab.context)$/.test(m)).join(","); log.push(`f${n} calls=${gl} top=${Math.round(r.top)} vis=${vis} sy=${window.scrollY} scr=[${scrolled.join(",")}] ${chain.join(" < ")}`);
    }
    if (n < 240) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
});
const q = new URLSearchParams({ entry, variant, locale: "en", theme: "Apple System Colors", colorScheme: "dark", frame: "component", width: "760", height: "600" });
const cdp = await p.context().newCDPSession(p); await cdp.send("Emulation.setCPUThrottlingRate", { rate: Number(process.env.CPU ?? 1) });
await p.goto(`http://127.0.0.1:8765/frame.html?${q}`);
await p.waitForTimeout(3000);
const log: string[] = await p.evaluate(() => (window as any).__log);
let prev = "";
for (const l of log) { { const t=l.split(" ").slice(2,4).join(" "); if (t!==prev){console.log(l.slice(0,260)); prev=t;} } }
await b.close();
