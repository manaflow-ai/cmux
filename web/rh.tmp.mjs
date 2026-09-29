import { chromium } from "playwright";
const [url, rootSel] = process.argv.slice(2);
const browser = await chromium.launch({ channel: "chrome" });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: "light" });
await ctx.addInitScript(() => localStorage.setItem("theme", "light"));
const page = await ctx.newPage();
await page.goto(url, { waitUntil: "load", timeout: 60000 });
await page.waitForTimeout(3000);
const rows = await page.evaluate((rootSel) => {
  const root = document.querySelector(rootSel);
  const fam = getComputedStyle(root).fontFamily.split(",")[0];
  const kids = [...root.querySelectorAll(":scope > *")].filter((e) => e.getBoundingClientRect().height > 0);
  const out = [`font-family: ${fam}`];
  let prev = null;
  for (const el of kids.slice(0, 26)) {
    const r = el.getBoundingClientRect(); const t = el.tagName.toLowerCase();
    const k = /^h\d$|^p$|^ul$|^ol$|^table$/.test(t) ? t : el.querySelector("pre") ? "code" : el.querySelector("table") ? "table" : t + "." + String(el.className).split(" ")[0].slice(0, 14);
    const tgt = /^(ul|ol)$/.test(t) ? el.querySelector("li") : el; const s = getComputedStyle(tgt);
    out.push(`${k.padEnd(18)} gap=${prev ? String(Math.round(r.top - prev.bottom)).padStart(3) : "  -"} ${s.fontSize}/${s.lineHeight} w${s.fontWeight}${/^(ul|ol)$/.test(t) && el.children[1] ? ` li-gap=${Math.round(el.children[1].getBoundingClientRect().top - el.children[0].getBoundingClientRect().bottom)}` : ""} | ${el.textContent.trim().slice(0, 34)}`);
    prev = r;
  }
  return out;
}, rootSel);
console.log(url + "\n" + rows.join("\n"));
await browser.close();
