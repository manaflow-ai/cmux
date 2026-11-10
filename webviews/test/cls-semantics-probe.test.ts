import { expect, setDefaultTimeout, test } from "bun:test";
import { chromium } from "playwright";

setDefaultTimeout(60_000);
const html = `<!doctype html><style>
body{margin:0} #s{position:absolute;top:28px;left:0;width:900px;height:672px;overflow:auto;overflow-anchor:none}
#t{position:relative;width:900px} .r{position:absolute;left:50px;width:800px;background:#ccc}
#line{height:22px;background:#f00}
</style><div id="s"><div id="t"></div></div>`;

for (const how of ["same-task", "next-raf", "resize-observer", "two-frames", "translate-hold"] as const)
  test(`cls when a block lands above the line, scroll set ${how}`, async () => {
    const browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    await page.setContent(html);
    const out = await page.evaluate(async (how) => {
      const s = document.getElementById("s")!;
      const t = document.getElementById("t")!;
      let y = 0;
      const add = (h: number, id: string) => {
        const r = document.createElement("div");
        r.className = "r";
        r.id = id;
        r.style.top = `${y}px`;
        r.style.height = `${h}px`;
        y += h + 10;
        t.append(r);
        return r;
      };
      for (let i = 0; i < 30; i++) add(60, `h${i}`);
      const line = add(22, "line");
      t.style.height = `${y + 100}px`;
      s.scrollTop = s.scrollHeight;
      const raf = () => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)));
      for (let i = 0; i < 5; i++) await raf();
      const shifts: { v: number; s: string[] }[] = [];
      new PerformanceObserver((list) => {
        for (const e of list.getEntries() as unknown as {
          value: number;
          sources: { node?: Node; previousRect: DOMRectReadOnly; currentRect: DOMRectReadOnly }[];
        }[])
          shifts.push({
            v: e.value,
            s: e.sources.map(
              (x) => `${(x.node as Element)?.id} ${Math.round(x.previousRect.y)}->${Math.round(x.currentRect.y)}`,
            ),
          });
      }).observe({ type: "layout-shift" });
      for (let k = 0; k < 4; k++) {
        // A 440px reply lands above the line.
        const lineTop = y - 32;
        const reply = document.createElement("div");
        reply.className = "r";
        reply.style.top = `${lineTop}px`;
        reply.style.height = "440px";
        t.insertBefore(reply, line);
        line.style.top = `${lineTop + 450}px`;
        y = lineTop + 450 + 32;
        t.style.height = `${y + 100}px`;
        const follow = () => (s.scrollTop = s.scrollHeight);
        if (how === "same-task") follow();
        else if (how === "next-raf") requestAnimationFrame(follow);
        else if (how === "resize-observer") {
          const ro = new ResizeObserver(() => {
            follow();
            ro.disconnect();
          });
          ro.observe(reply);
        } else if (how === "two-frames") await raf().then(follow);
        else {
          // The view lands at once and the thread is drawn back (the follow chase's translate).
          const before = s.scrollTop;
          follow();
          t.style.translate = `0 ${s.scrollTop - before - 450}px`;
          await raf();
          t.style.translate = "";
        }
        for (let i = 0; i < 4; i++) await raf();
      }
      await raf();
      return { total: shifts.reduce((a, b) => a + b.v, 0), shifts };
    }, how);
    console.log(`SEMANTICS ${how} cls=${out.total.toFixed(4)} ${JSON.stringify(out.shifts.slice(0, 4))}`);
    await browser.close();
    expect(out.total).toBeGreaterThanOrEqual(0);
  });
