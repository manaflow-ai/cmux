// Builds the art-aware crop gallery: decodes each artwork to raw RGB in
// headless Chromium, runs the Rust example `art_crop` (cmux-follow-cam) on
// it, writes data.js and resize.js, renders one PNG per artwork from
// index.html and records the live-resize video from resize.html.
//
//   PLAYWRIGHT_CORE=/path/to/playwright-core/index.js node build.js [--no-cargo]
//
// Outputs go to out/ (art-<name>.png, resize.webm).

const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HERE = __dirname;
const REPO = path.resolve(HERE, '../..');
const ART_DIR = path.join(REPO, 'Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/BackdropArt');
const OUT = path.join(HERE, 'out');
const ARTWORKS = [
  // framing: a hand-set focus (0..1) and bleed (left, top, right, bottom),
  // here the blurred fill left of the painting; shown as a third row.
  { name: 'friedrich-wanderer', title: 'Friedrich, Wanderer above the Sea of Fog', framing: '0.77,0.42,0.6,0,0,0' },
  { name: 'vermeer-pearl-earring', title: 'Vermeer, Girl with a Pearl Earring' },
  { name: 'millais-joan-of-arc', title: 'Millais, Joan of Arc', framing: '0.84,0.2,0.53,0,0,0' },
];
const RESIZE_ART = process.env.RESIZE_ART || 'friedrich-wanderer';

async function toRgb(page, file) {
  const b64 = fs.readFileSync(file).toString('base64');
  const res = await page.evaluate(async (d) => {
    const img = new Image();
    img.src = 'data:image/avif;base64,' + d;
    await img.decode();
    const c = document.createElement('canvas');
    c.width = img.naturalWidth; c.height = img.naturalHeight;
    const g = c.getContext('2d');
    g.drawImage(img, 0, 0);
    const px = g.getImageData(0, 0, c.width, c.height).data;
    const out = new Uint8Array(c.width * c.height * 3);
    for (let i = 0, j = 0; i < px.length; i += 4, j += 3) { out[j] = px[i]; out[j + 1] = px[i + 1]; out[j + 2] = px[i + 2]; }
    let s = '';
    for (let i = 0; i < out.length; i += 0x8000) s += String.fromCharCode.apply(null, out.subarray(i, i + 0x8000));
    return { w: c.width, h: c.height, b64: btoa(s) };
  }, b64);
  return { w: res.w, h: res.h, rgb: Buffer.from(res.b64, 'base64') };
}

function example(args) {
  const out = execFileSync('cargo', ['run', '-q', '--release', '-p', 'cmux-follow-cam', '--example', 'art_crop', '--', ...args], {
    cwd: path.join(REPO, 'cmux-tui'), maxBuffer: 64 << 20,
  });
  return JSON.parse(out.toString());
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'art-crop-'));
  const browser = await chromium.launch({ args: ['--allow-file-access-from-files'] });
  const page = await browser.newPage();
  const artworks = [];
  let resize = null;
  for (const art of ARTWORKS) {
    const file = `${art.name}.avif`;
    const { w, h, rgb } = await toRgb(page, path.join(ART_DIR, file));
    const raw = path.join(tmp, `${art.name}.rgb`);
    fs.writeFileSync(raw, rgb);
    const data = example(['regions', raw, String(w), String(h), ...(art.framing ? [art.framing] : [])]);
    delete data.map;
    artworks.push({ ...art, file, ...data, framing: data.framing });
    if (art.name === RESIZE_ART) resize = { ...example(['resize', raw, String(w), String(h), '30']), file, title: art.title };
    console.log(art.name, JSON.stringify(data.regions.map(r => [Math.round(r.x), Math.round(r.y), Math.round(r.w), Math.round(r.h), +r.weight.toFixed(2)])));
  }
  fs.writeFileSync(path.join(HERE, 'data.js'), 'window.ART_CROP = ' + JSON.stringify({ artworks }, null, 1) + ';\n');
  fs.writeFileSync(path.join(HERE, 'resize.js'), 'window.ART_RESIZE = ' + JSON.stringify(resize) + ';\n');

  // One PNG per artwork.
  const shot = await browser.newPage({ viewport: { width: 1800, height: 900 }, deviceScaleFactor: 1 });
  for (const art of ARTWORKS) {
    await shot.goto('file://' + path.join(HERE, 'index.html') + '?art=' + art.name);
    await shot.waitForSelector('body[data-ready="1"]');
    await (await shot.$('section')).screenshot({ path: path.join(OUT, `art-${art.name}.png`) });
  }

  // The live-resize video.
  const ctx = await browser.newContext({ viewport: { width: 1600, height: 900 }, recordVideo: { dir: tmp, size: { width: 1600, height: 900 } } });
  const vp = await ctx.newPage();
  await vp.goto('file://' + path.join(HERE, 'resize.html'));
  await vp.waitForSelector('body[data-ready="1"]');
  await vp.evaluate(() => window.play());
  await vp.waitForSelector('body[data-done="1"]', { timeout: 20000 });
  await vp.waitForTimeout(600);
  // Stills of the video at four moments, to look at without a player.
  for (const t of [0.5, 2.0, 3.8, 7.6]) {
    await vp.evaluate((t) => window.show(t), t);
    await vp.screenshot({ path: path.join(OUT, `resize-t${t.toFixed(1)}.png`) });
  }
  const video = vp.video();
  await ctx.close();
  fs.copyFileSync(await video.path(), path.join(OUT, 'resize.webm'));
  await browser.close();
  console.log('wrote', fs.readdirSync(OUT).join(', '));
})();
