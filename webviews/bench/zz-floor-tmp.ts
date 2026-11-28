import { webkit } from "playwright";
const html = `<!doctype html><body style="margin:0;font:14px system-ui"><div style="height:600px;overflow:auto">${"<p>row text ".repeat(60)}</div>
<div id=f contenteditable style="position:fixed;bottom:10px;left:100px;width:700px;min-height:40px;border:1px solid #ccc;padding:8px"></div>
<script>
const s=[];let k;f.addEventListener('keydown',e=>{const t=performance.now();requestAnimationFrame(a=>{const r1=performance.now();requestAnimationFrame(()=>{s.push([r1-t,performance.now()-t])})})});
window.reset=()=>{s.length=0};window.stats=()=>{const q=(a,p)=>{a=[...a].sort((x,y)=>x-y);return +a[Math.floor(p*(a.length-1))].toFixed(1)};const a=s.map(x=>x[0]),b=s.map(x=>x[1]);return {n:s.length,frame_p50:q(a,.5),frame_p95:q(a,.95),frame_p99:q(a,.99),f2_p95:q(b,.95),f2_p99:q(b,.99)}};
</script></body>`;
const browser = await webkit.launch();
const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
await page.setContent(html);
await page.click("#f"); for (let i = 0; i < 60; i++) await page.keyboard.press("x"); await page.evaluate(() => { (window as any).stats0 = 1; }); await page.waitForTimeout(500); await page.evaluate(() => { (window as any).reset?.(); });
const start = performance.now();
for (let i = 0; i < 500; i++) { const due = start + i * 20; await new Promise(r => setTimeout(r, Math.max(0, due - performance.now()))); await page.keyboard.press("abcdefghijklmnopqrstuvwxyz"[i % 26]); }
await page.waitForTimeout(200);
console.log(JSON.stringify(await page.evaluate(() => (window as any).stats())));
await browser.close();
