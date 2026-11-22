// Measurement only (not committed): vite.config.ts plus an in-page stage probe.
import base from "./vite.config";
import fs from "node:fs";
const LOG = process.env.HSS_LOG ?? "/tmp/hss-probe.ndjson";
const log = (o: object) => fs.appendFileSync(LOG, JSON.stringify({ srv: Date.now(), ...o }) + "\n");
const PORT = Number(process.env.CMUX_WEBVIEWS_DEV_PORT ?? 4417);
const early = `(function(){var T=function(){return performance.timeOrigin+performance.now()};
var S=function(o){o.page=location.pathname;o.vis=document.visibilityState;o.focus=document.hasFocus();try{navigator.sendBeacon("http://127.0.0.1:${PORT}/__hss_log",JSON.stringify(o))}catch(e){}};
window.__hss={T:T,S:S};var N=window.WebSocket;if(!N)return;
window.WebSocket=class extends N{constructor(u,p){super(u,p);if(!([].concat(p||[])).includes("vite-hmr"))return;
this.addEventListener("message",function(e){var t=T();try{var m=JSON.parse(e.data);if(m.type==="update"||m.type==="full-reload")S({ev:"ws",t:t,type:m.type,ts:m.updates&&m.updates[0]&&m.updates[0].timestamp,paths:(m.updates||[]).map(function(u){return u.path})})}catch(x){}});}};
var armed=0;new MutationObserver(function(){if(!armed)return;armed=0;var t=T();S({ev:"mut",t:t});requestAnimationFrame(function(){var a=T();requestAnimationFrame(function(){S({ev:"raf",t1:a,t2:T()})})})}).observe(document,{subtree:true,childList:true,characterData:true});
window.__hssArm=function(){armed=1};})();`;
const late = `import { createHotContext } from "/@vite/client";
const hot = createHotContext("/__hss_probe");
hot.on("vite:beforeUpdate", (p) => { window.__hssArm && window.__hssArm(); window.__hss.S({ ev: "before", t: window.__hss.T(), n: p.updates.length }); });
hot.on("vite:afterUpdate", () => window.__hss.S({ ev: "after", t: window.__hss.T() }));
window.__hss.S({ ev: "load", t: window.__hss.T() });`;
export default {
  ...base,
  plugins: [
    ...(base.plugins ?? []),
    {
      name: "hss-probe",
      apply: "serve",
      transformIndexHtml() {
        return [
          { tag: "script", children: early, injectTo: "head-prepend" },
          { tag: "script", attrs: { type: "module" }, children: late, injectTo: "body" },
        ];
      },
      configureServer(server) {
        server.watcher.on("change", (f) => log({ ev: "watch", file: f }));
        server.middlewares.use((req, res, next) => {
          if (req.url === "/__hss_log") {
            let body = ""; req.on("data", (c) => (body += c));
            req.on("end", () => { try { log({ ev: "page", ...JSON.parse(body) }); } catch {} res.statusCode = 204; res.end(); });
            return;
          }
          if (req.url && /[?&]t=\d+/.test(req.url)) {
            const t0 = Date.now(); log({ ev: "req", url: req.url });
            res.on("finish", () => log({ ev: "res", url: req.url, ms: Date.now() - t0 }));
          }
          next();
        });
      },
      hotUpdate() { log({ ev: "hot", file: this.environment?.name }); },
    },
  ],
};
