import { chromium } from "playwright";
import { mkdir, writeFile } from "node:fs/promises";

const targets = [
  ["vercel", "https://vercel.com"],
  ["linear", "https://linear.app"],
  ["raycast", "https://raycast.com"],
  ["stripe", "https://stripe.com"],
  ["supabase", "https://supabase.com"],
  ["resend", "https://resend.com"],
];

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox", "--disable-gpu"] });
await mkdir("research/data", { recursive: true });
const results = [];

for (const [name, url] of targets) {
  console.error(`measuring ${name}`);
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await context.tracing.start({ screenshots: false, snapshots: false, sources: false });
  const page = await context.newPage();
  await page.route("**/*", async (route) => {
    const type = route.request().resourceType();
    if (["image", "media", "font"].includes(type)) return route.abort();
    return route.continue();
  });
  const started = Date.now();
  let error = null;
  try {
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30_000 });
    await page.waitForTimeout(750);
  } catch (cause) {
    error = String(cause);
  }
  const data = await page.evaluate(() => {
    const visible = (element) => {
      const box = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return box.width > 0 && box.height > 0 && style.visibility !== "hidden" && style.display !== "none";
    };
    const compact = (element) => {
      if (!element) return null;
      const style = getComputedStyle(element);
      const box = element.getBoundingClientRect();
      return {
        tag: element.tagName.toLowerCase(),
        text: (element.textContent || "").replace(/\s+/g, " ").trim().slice(0, 140),
        rect: { x: Math.round(box.x), y: Math.round(box.y), width: Math.round(box.width), height: Math.round(box.height) },
        font: {
          family: style.fontFamily,
          size: style.fontSize,
          weight: style.fontWeight,
          lineHeight: style.lineHeight,
          letterSpacing: style.letterSpacing,
        },
        color: style.color,
        background: style.backgroundColor,
        transition: `${style.transitionDuration} ${style.transitionTimingFunction}`,
        animation: `${style.animationDuration} ${style.animationTimingFunction}`,
      };
    };
    const parseColor = (value) => {
      const rgb = value.match(/rgba?\(\s*([\d.]+)[, ]+\s*([\d.]+)[, ]+\s*([\d.]+)/);
      if (rgb) return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3])];
      const oklch = value.match(/oklch\(\s*([\d.]+)%?\s+([\d.]+)%?\s+([\d.]+)/);
      if (!oklch) return null;
      const L = Number(oklch[1]) > 1 ? Number(oklch[1]) / 100 : Number(oklch[1]);
      const C = Number(oklch[2]) > 1 ? Number(oklch[2]) / 100 : Number(oklch[2]);
      const h = Number(oklch[3]) * Math.PI / 180;
      const a = C * Math.cos(h);
      const b = C * Math.sin(h);
      const l1 = Math.pow(L + 0.3963377774 * a + 0.2158037573 * b, 3);
      const m1 = Math.pow(L - 0.1055613458 * a - 0.0638541728 * b, 3);
      const s1 = Math.pow(L - 0.0894841775 * a - 1.291485548 * b, 3);
      const linear = [
        4.0767416621 * l1 - 3.3077115913 * m1 + 0.2309699292 * s1,
        -1.2684380046 * l1 + 2.6097574011 * m1 - 0.3413193965 * s1,
        -0.0041960863 * l1 - 0.7034186147 * m1 + 1.707614701 * s1,
      ];
      return linear.map((channel) => 255 * (channel <= 0.0031308 ? 12.92 * channel : 1.055 * Math.pow(channel, 1 / 2.4) - 0.055));
    };
    const luminance = (rgb) => rgb.reduce((sum, channel, index) => {
      const c = Math.max(0, Math.min(255, channel)) / 255;
      const linear = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
      return sum + linear * [0.2126, 0.7152, 0.0722][index];
    }, 0);
    const contrastRatio = (foreground, background) => {
      const fg = parseColor(foreground);
      const bg = parseColor(background);
      if (!fg || !bg) return null;
      const [lighter, darker] = [luminance(fg), luminance(bg)].sort((a, b) => b - a);
      return Math.round(((lighter + 0.05) / (darker + 0.05)) * 100) / 100;
    };
    const h1 = [...document.querySelectorAll("h1")].find(visible);
    const heading = h1 || [...document.querySelectorAll("h2")].find(visible);
    const paragraph = heading
      ? [...document.querySelectorAll("p")].find((el) => visible(el) && el.getBoundingClientRect().top >= heading.getBoundingClientRect().bottom - 2)
      : null;
    const cta = [...document.querySelectorAll("a,button")].find((el) => {
      if (!visible(el)) return false;
      const text = (el.textContent || "").replace(/\s+/g, " ").trim().toLowerCase();
      return /get started|start|deploy|try|sign up|contact|download|talk to|book|learn/.test(text);
    });
    const motion = [];
    for (const element of [...document.querySelectorAll("*")].slice(0, 500)) {
      if (!visible(element)) continue;
      const style = getComputedStyle(element);
      const hasMotion = style.transitionDuration !== "0s" || style.animationDuration !== "0s";
      if (hasMotion) {
        motion.push({
          tag: element.tagName.toLowerCase(),
          className: String(element.className || "").slice(0, 120),
          transition: `${style.transitionProperty}: ${style.transitionDuration} ${style.transitionTimingFunction}`,
          animation: `${style.animationName}: ${style.animationDuration} ${style.animationTimingFunction}`,
        });
      }
      if (motion.length >= 24) break;
    }
    const root = getComputedStyle(document.documentElement);
    return {
      title: document.title,
      viewport: { width: innerWidth, height: innerHeight, dpr: devicePixelRatio },
      body: compact(document.body),
      heading: compact(heading),
      paragraph: compact(paragraph),
      cta: compact(cta),
      nav: compact(document.querySelector("header, nav")),
      root: { fontFamily: root.fontFamily, fontSize: root.fontSize, lineHeight: root.lineHeight },
      contrast: {
        headingOnBody: heading ? contrastRatio(getComputedStyle(heading).color, getComputedStyle(document.body).backgroundColor) : null,
        paragraphOnBody: paragraph ? contrastRatio(getComputedStyle(paragraph).color, getComputedStyle(document.body).backgroundColor) : null,
      },
      motion,
      scrollHeight: document.documentElement.scrollHeight,
    };
  });
  console.error(`evaluated ${name}`);
  const tracePath = `research/data/${name}.trace.zip`;
  await context.tracing.stop({ path: tracePath });
  await context.close();
  console.error(`closed ${name}`);
  results.push({ name, url, elapsedMs: Date.now() - started, error, ...data, trace: tracePath });
}

await browser.close();
await writeFile("research/data/site-metrics.json", `${JSON.stringify({ measuredAt: new Date().toISOString(), results }, null, 2)}\n`);
console.log(JSON.stringify(results, null, 2));
