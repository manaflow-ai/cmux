import { createRequire } from "node:module";
const require = createRequire(process.cwd() + "/package.json");
const { chromium } = require("playwright");
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 760, height: 480 }, deviceScaleFactor: 2 });
await p.goto("http://127.0.0.1:8791/gallery/frame.html?entry=agent-pane.chat-motion-pass&scheme=dark");
await p.waitForFunction(() => document.body.dataset.galleryReady || document.querySelector("li"), null, {timeout: 60000}).catch(()=>{}); await p.waitForTimeout(1500); console.log(await p.evaluate(()=>[...document.querySelectorAll("li")].map(l=>l.textContent.slice(0,40)).join(" | ")));
await p.waitForTimeout(4000);
console.log("frames", p.frames().length, await p.evaluate(()=>document.body.innerText.slice(0,200)));
const out = await p.evaluate(() => {
  const li = [...document.querySelectorAll("li")].find((e) => e.textContent.includes("health check"));
  const chain = [];
  for (let e = li; e && chain.length < 16; e = e.parentElement) {
    const cs = getComputedStyle(e);
    chain.push(`${e.tagName}.${e.className} [${[...e.attributes].filter(a=>a.name.startsWith("data-")).map(a=>a.name+"="+a.value).join(" ")}] x=${Math.round(e.getBoundingClientRect().x)} pl=${cs.paddingLeft} ml=${cs.marginLeft} tf=${cs.transform} anim=${e.getAnimations().map(a=>a.animationName||a.id).join(",")}`);
  }
  return chain.join("\n");
});
console.log(out ?? "none");
await b.close().catch(()=>{});
