// l10n-allow-file: measurement tool, no shipped UI.
// The perturbation pass (RFD 0040, the closed kit's meter): render gallery states with one design input
// at its base value and again moved, and print the follow rate, the share of rendered rounded corners
// that moved by the amount the input's rule derives. A corner that should move and does not is a
// hand-set value, whatever its source looks like.
//
// Usage: bun run gallery:perturb [--input radius.control=10] [--entry ID[:VARIANT] ...] [--all]
//          [--scheme light] [--background none] [--json FILE] [--verbose]
//   --input   the input and its moved value. The one input today is radius.control, the control corner
//             (`--cmux-button-radius`, the App's Metrics.buttonCornerRadius; desktop.css derives
//             `--ds-radius-control` from it), base 8.
//   --entry   gallery entries to render, every variant of each, or one variant with ID:VARIANT
//             (repeatable). Default: kit.primitives, whose session variants hold kit/presets, the
//             first closed directory (tsconfig.closed.json).
//   --all     every entry and variant in the gallery (thousands of renders; tens of minutes).
//
// The rule (design-system.md rule 4): every corner is the control corner plus an inset, capped at a
// third of the box's shorter side. So when the control corner moves by d, a corner r moves to r + d,
// and a corner already at or past its cap holds. Each rendered corner (a box that paints a fill, a
// border, a shadow or a backdrop, has a size, and a non-zero radius) is one of:
//   followed  moved by d (within half a pixel);
//   capped    at or past a third of its shorter side, and held (or stayed past the cap);
//   stuck     not capped, and did not move: a hand-set or unrelated corner;
//   off       moved by some other amount (a corner computed from the input another way);
//   gone      painted in the base render and not in the moved one (or the other way round).
// The follow rate is (followed + capped) / all. Boxes are matched across the two renders by their
// path in the DOM (open shadow roots included), so a state that renders different boxes at the two
// values reports them as gone rather than guessing.
//
// It builds the gallery (dist/gallery) when there is none, or when CMUX_CAPTURE_BUILD=1.
// On a lane VM: `cmux-ci test -- bun run gallery:perturb --input radius.control=10`.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { parseArgs } from "node:util";
import { chromium, type Browser } from "playwright";
import { preview } from "vite";
import { loadEntries } from "./entries";

/** The inputs the pass can move: the custom property the App sets, and its base value in px. */
const INPUTS: Record<string, { property: string; base: number }> = {
  "radius.control": { property: "--cmux-button-radius", base: 8 },
};
const DEFAULT_ENTRIES = ["kit.primitives"];
/** Half a pixel: a computed radius within this of the expected one moved by the derived amount. */
const SLACK = 0.5;

const { values } = parseArgs({
  options: {
    input: { type: "string", default: "radius.control=10" },
    entry: { type: "string", multiple: true, default: [] },
    all: { type: "boolean", default: false },
    scheme: { type: "string", default: "light" },
    background: { type: "string", default: "none" },
    json: { type: "string" },
    verbose: { type: "boolean", default: false },
  },
});

const [inputName, movedText] = values.input!.split("=");
const input = INPUTS[inputName ?? ""];
const moved = Number(movedText);
if (!input || !Number.isFinite(moved)) {
  console.error(`gallery:perturb: --input takes NAME=PX with NAME one of ${Object.keys(INPUTS).join(", ")}`);
  process.exit(2);
}
const delta = moved - input.base;

type Corner = { key: string; r: number; min: number };
type Outcome = "followed" | "capped" | "stuck" | "off" | "gone";
type StateResult = { state: string; counts: Record<Outcome, number>; samples: string[]; error?: string };

const entries = await loadEntries();
const picked = values.entry!.length > 0 ? values.entry! : values.all ? [] : DEFAULT_ENTRIES;
const states: { id: string; variant: string; height: number }[] = [];
for (const entry of entries) {
  const asked = picked.filter((pick) => pick === entry.id || pick.startsWith(`${entry.id}:`));
  if (picked.length > 0 && asked.length === 0) continue;
  const only = asked.flatMap((pick) => (pick.includes(":") ? [pick.slice(entry.id.length + 1)] : []));
  for (const variant of Object.keys(entry.variants)) {
    if (only.length > 0 && !only.includes(variant)) continue;
    states.push({ id: entry.id, variant, height: Math.min(entry.height ?? 600, 2000) });
  }
}
for (const pick of picked)
  if (!entries.some((entry) => entry.id === pick.split(":")[0]))
    console.error(`gallery:perturb: no gallery entry ${pick}`);
if (states.length === 0) {
  console.error("gallery:perturb: nothing to render");
  process.exit(2);
}

const root = path.resolve(import.meta.dir, "../..");
if (!fs.existsSync(path.join(root, "dist/gallery")) || process.env.CMUX_CAPTURE_BUILD === "1") {
  const build = spawn("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
  await new Promise((resolve, reject) => {
    build.once("error", reject);
    build.once("exit", (code) => (code === 0 ? resolve(code) : reject(new Error(`gallery build exited ${code}`))));
  });
}
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const address = server.httpServer.address();
if (!address || typeof address === "string") throw new Error("gallery preview did not bind a TCP port");
const baseUrl = `http://127.0.0.1:${address.port}`;

/** Every painted rounded corner in the page, keyed by its box's DOM path and the corner's name. */
async function corners(browser: Browser, state: (typeof states)[number], px: number): Promise<Corner[]> {
  const context = await browser.newContext({
    viewport: { width: 1280, height: state.height },
    deviceScaleFactor: 1,
    colorScheme: values.scheme === "dark" ? "dark" : "light",
    reducedMotion: "reduce",
  });
  try {
    const page = await context.newPage();
    const query = new URLSearchParams({
      entry: state.id,
      variant: state.variant,
      colorScheme: values.scheme!,
      width: "normal",
      frame: "component",
    });
    if (values.background !== "none") query.set("background", values.background!);
    // The input is set before the page's own sheets run, on the root and every shadow root, as the
    // App sets it on the page; `!important` so a gallery fixture cannot pin it.
    await page.addInitScript(
      ([property, value]) => {
        const css = `:root, :host { ${property}: ${value} !important; }`;
        const add = (target: Document | ShadowRoot) => {
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(css);
          target.adoptedStyleSheets = [...target.adoptedStyleSheets, sheet];
        };
        add(document);
        const attach = Element.prototype.attachShadow;
        Element.prototype.attachShadow = function (init) {
          const shadow = attach.call(this, init);
          add(shadow);
          return shadow;
        };
      },
      [input!.property, `${px}px`] as const,
    );
    await page.goto(`${baseUrl}/frame.html?${query}`, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 90_000 });
    if ((await page.evaluate(() => document.documentElement.dataset.galleryReady)) !== "1")
      throw new Error("the state did not render (galleryReady is not 1)");
    await page.evaluate(
      () =>
        new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 300)))),
    );
    return await page.evaluate(() => {
      const out: { key: string; r: number; min: number }[] = [];
      const transparent = (color: string) => color === "transparent" || /rgba?\([^)]*,\s*0\)$/.test(color);
      const paints = (style: CSSStyleDeclaration) =>
        !transparent(style.backgroundColor) ||
        style.backgroundImage !== "none" ||
        style.boxShadow !== "none" ||
        (style.backdropFilter && style.backdropFilter !== "none") ||
        ["Top", "Right", "Bottom", "Left"].some(
          (side) =>
            parseFloat(style.getPropertyValue(`border-${side.toLowerCase()}-width`)) > 0 &&
            style.getPropertyValue(`border-${side.toLowerCase()}-style`) !== "none" &&
            !transparent(style.getPropertyValue(`border-${side.toLowerCase()}-color`)),
        );
      const corner = ["top-left", "top-right", "bottom-right", "bottom-left"];
      const visit = (node: Element | ShadowRoot, prefix: string) => {
        let index = 0;
        for (const child of Array.from(node.children)) {
          const key = `${prefix}/${child.localName}[${index++}]`;
          const style = getComputedStyle(child);
          if (style.display === "none") continue;
          const box = child.getBoundingClientRect();
          if (style.visibility !== "hidden" && box.width > 0 && box.height > 0 && paints(style)) {
            const min = Math.min(box.width, box.height);
            for (const name of corner) {
              // "8px", "8px 6px" (elliptical: the horizontal radius), or a percentage of the box.
              const raw = style.getPropertyValue(`border-${name}-radius`).split(" ")[0] ?? "0px";
              const r = raw.endsWith("%") ? (parseFloat(raw) / 100) * box.width : parseFloat(raw);
              if (r > 0) out.push({ key: `${key}:${name}`, r, min });
            }
          }
          if (child.shadowRoot) visit(child.shadowRoot, `${key}#shadow`);
          visit(child, key);
        }
      };
      visit(document.documentElement, "");
      return out;
    });
  } finally {
    await context.close();
  }
}

function judge(base: Corner[], next: Corner[]): { counts: Record<Outcome, number>; samples: string[] } {
  const counts: Record<Outcome, number> = { followed: 0, capped: 0, stuck: 0, off: 0, gone: 0 };
  const samples: string[] = [];
  const after = new Map(next.map((corner) => [corner.key, corner]));
  const seen = new Set<string>();
  for (const corner of base) {
    const other = after.get(corner.key);
    seen.add(corner.key);
    if (!other) {
      counts.gone += 1;
      continue;
    }
    const cap = corner.min / 3;
    const moved = other.r - corner.r;
    let outcome: Outcome;
    if (Math.abs(moved - delta) <= SLACK) outcome = "followed";
    else if (corner.r >= cap - SLACK && (Math.abs(moved) <= SLACK || other.r >= other.min / 3 - SLACK))
      outcome = "capped";
    else if (Math.abs(moved) <= SLACK) outcome = "stuck";
    else outcome = "off";
    counts[outcome] += 1;
    if ((outcome === "stuck" || outcome === "off") && samples.length < 12)
      samples.push(`${outcome} ${corner.r}px -> ${other.r}px (box ${Math.round(corner.min)}px) ${corner.key}`);
  }
  for (const corner of next) if (!seen.has(corner.key)) counts.gone += 1;
  return { counts, samples };
}

const rate = (counts: Record<Outcome, number>) => {
  const all = Object.values(counts).reduce((sum, n) => sum + n, 0);
  return { all, rate: all === 0 ? NaN : (counts.followed + counts.capped) / all };
};
const percent = (value: number) => (Number.isNaN(value) ? "n/a" : `${(value * 100).toFixed(1)}%`);

const started = performance.now();
const results: StateResult[] = [];
const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
try {
  for (const state of states) {
    const name = `${state.id}:${state.variant}`;
    try {
      const base = await corners(browser, state, input.base);
      const next = await corners(browser, state, moved);
      const { counts, samples } = judge(base, next);
      results.push({ state: name, counts, samples });
      const { all, rate: value } = rate(counts);
      console.log(
        `${name}: ${percent(value)} of ${all} corners (followed ${counts.followed}, capped ${counts.capped}, stuck ${counts.stuck}, off ${counts.off}, gone ${counts.gone})`,
      );
      if (values.verbose) for (const sample of samples) console.log(`  ${sample}`);
    } catch (error) {
      const message = String(error).split("\n")[0]!.slice(0, 200);
      results.push({
        state: name,
        counts: { followed: 0, capped: 0, stuck: 0, off: 0, gone: 0 },
        samples: [],
        error: message,
      });
      console.log(`${name}: not rendered (${message})`);
    }
  }
} finally {
  await browser.close();
  await new Promise<void>((resolve) => server.httpServer.close(() => resolve()));
}

const total: Record<Outcome, number> = { followed: 0, capped: 0, stuck: 0, off: 0, gone: 0 };
for (const result of results) for (const key of Object.keys(total) as Outcome[]) total[key] += result.counts[key];
const { all, rate: value } = rate(total);
const failed = results.filter((result) => result.error).length;
const seconds = (performance.now() - started) / 1000;
console.log(
  `\nfollow rate (${inputName} ${input.base} -> ${moved}px, ${values.scheme}, background ${values.background}): ` +
    `${percent(value)} of ${all} corners in ${results.length - failed} states ` +
    `(followed ${total.followed}, capped ${total.capped}, stuck ${total.stuck}, off ${total.off}, gone ${total.gone}; ` +
    `moved by +${delta}px alone ${percent(all === 0 ? NaN : total.followed / all)}); ` +
    `${failed} states not rendered; ${(results.length - failed) * 2} renders in ${seconds.toFixed(0)} s`,
);
if (values.json)
  fs.writeFileSync(
    values.json,
    JSON.stringify({ input: values.input, scheme: values.scheme, total, results }, null, 2),
  );
