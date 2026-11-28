import fs from "node:fs"; import {PNG} from "pngjs"; import pixelmatch from "pixelmatch";
for (const f of fs.readdirSync("/tmp/blf/head").filter(f=>f.endsWith(".png"))) {
  const h=PNG.sync.read(fs.readFileSync("/tmp/blf/head/"+f));
  const out=[];
  for (const o of ["parent","base"]) { const p=PNG.sync.read(fs.readFileSync(`/tmp/blf/${o}/`+f));
    const n=pixelmatch(h.data,p.data,null,h.width,h.height,{threshold:0.1}); out.push(`${o}=${(100*n/(h.width*h.height)).toFixed(2)}%`);}
  console.log(f,out.join(" "));
}
