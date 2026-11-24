// Per look x scheme: the golden mock-app window; read every control's contrast (the control contrast audit's
// own scan: markControls, hideInk, readControls) in the top page (sidebar, tabs) and in the pane frame.
import fs from "node:fs";
import path from "node:path";
import { chromium, type Frame, type Page } from "playwright";
import { preview } from "vite";
import {
  hideInk,
  markControls,
  readControls,
} from "../test/support/controlContrastScan"; /* run from webviews/scripts/ */
const root = path.resolve(import.meta.dir, "..");
const looks = JSON.parse(fs.readFileSync(path.join(root, "src/gallery/golden/looks.json"), "utf8"));
const ids: string[] = (Array.isArray(looks) ? looks : (looks.looks ?? Object.keys(looks))).map((l: any) =>
  typeof l === "string" ? l : l.id,
);
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const base = `http://127.0.0.1:${(server.httpServer.address() as any).port}`;
const browser = await chromium.launch();
const out = fs.createWriteStream(process.argv[2] ?? "/tmp/lcscan/out.jsonl");
const MIN = { text: 4.5, large: 3, icon: 3, disabled: 2.5 };
async function read(target: Page | Frame, shot: () => Promise<Buffer>) {
  await target.addStyleTag({ content: "*,*::before,*::after{transition:none!important;animation:none!important}" });
  const controls = await target.evaluate(markControls);
  if (!controls.length) return { controls: 0, fails: [] };
  const url = async () => `data:image/png;base64,${(await shot()).toString("base64")}`;
  const drawn = await url();
  const ink = await target.evaluate(hideInk, true);
  const bare = await url();
  await target.evaluate(hideInk, false);
  const readings = await target.evaluate(readControls, { drawn, bare, scale: 2, controls, ink });
  const fails = [];
  for (const r of readings as any[]) {
    const c = (controls as any[])[r.id];
    const min = c.disabled ? MIN.disabled : r.kind === "icon" ? MIN.icon : c.large ? MIN.large : MIN.text;
    if (r.ratio + 0.005 < min)
      fails.push({
        label: c.label,
        kind: r.kind,
        ratio: +r.ratio.toFixed(2),
        min,
        ink: r.ink,
        ground: r.ground,
        px: r.pixels,
      });
  }
  return { controls: controls.length, fails };
}
const ctx = await browser.newContext({ viewport: { width: 1344, height: 1000 }, deviceScaleFactor: 2 });
const schemes = (process.env.LC_SCHEMES ?? "light,dark").split(",");
const styleMap: Record<string, string> = process.env.LC_STYLE_MAP
  ? JSON.parse(fs.readFileSync(process.env.LC_STYLE_MAP, "utf8"))
  : {};
const only = process.env.LC_LOOKS?.split(",");
const jobs: [number, string, string][] = [];
for (let pass = 0; pass < Number(process.env.LC_PASSES ?? 1); pass++)
  for (const id of ids) if (!only || only.includes(id)) for (const scheme of schemes) jobs.push([pass, id, scheme]);
await Promise.all(
  Array.from({ length: Number(process.env.LC_WORKERS ?? 6) }, async () => {
    for (let job = jobs.shift(); job; job = jobs.shift()) {
      const [pass, id, scheme] = job;
      {
        const page = await ctx.newPage();
        const res: any = { look: id, scheme, pass };
        try {
          const q = new URLSearchParams({
            fixture: `looks.golden/${id}`,
            colorScheme: scheme,
            window: "1280x900",
            zoom: "1",
          });
          await page.goto(`${base}/mock-app.html?${q}`, { waitUntil: "domcontentloaded" });
          const frame = await (async () => {
            for (let i = 0; i < 120; i++) {
              const f = page.frames().find((c) => c.url().includes("frame.html"));
              if (f) return f;
              await page.waitForTimeout(250);
            }
            throw new Error("no pane frame");
          })();
          await frame.waitForSelector(".cv-user__bubble", { timeout: 60000 });
          await page.waitForTimeout(800);
          res.window = { controls: 0, fails: [] };
          const style = styleMap[`${id}:${scheme}`] ?? styleMap[id] ?? process.env.LC_STYLE;
          if (style) {
            await frame.addStyleTag({ content: style });
            await page.waitForTimeout(200);
          }
          const el = await frame.frameElement();
          res.pane = await read(frame, () => el.screenshot({ type: "png", animations: "disabled", caret: "hide" }));
        } catch (e) {
          res.error = String(e).split("\n")[0].slice(0, 160);
        }
        out.write(JSON.stringify(res) + "\n");
        console.log(
          id,
          scheme,
          res.error ??
            `${res.window.controls}+${res.pane.controls} controls, ${res.window.fails.length + res.pane.fails.length} under`,
        );
        await page.close();
      }
    }
  }),
);
out.end();
await browser.close();
server.httpServer.close();
process.exit(0);
