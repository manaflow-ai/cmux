// One registry for every icon (Leo, 2026-11-22: "dont get cute about it; let's just do claude and
// codex's symbol for branching/forking chats ... go look for good icons while you're at it. customize
// and design our own if we want. like, we can hill climb this."). Hill-climbing a drawing only works
// when every icon comes from one place and is drawn to one spec, so this test holds both:
//
// (a) design/icons/source (the registry build_pack.py generates the web pack, the native pack and the
//     catalog from) follows design/icons/SPEC.md: every drawing (line, solid, cat, alts) is on the
//     0 0 24 24 grid; Line and Cat strokes are 1.5 wide, round caps and joins, currentColor (the Cat
//     cue var(--accent)); Solid strokes are 1.5 (a silhouette's outline) or 2 (an open shape), and a
//     Solid with no fill is Line's drawing at 2; masks are named cmxs-<icon>. Named exceptions below,
//     each with its reason; one test fails when an exception no longer needs listing.
// (b) Nothing outside the registry draws its own icon: web code under webviews/src imports no icon
//     library and adds no inline <svg> beyond iconRegistryBaseline.json, and native code adds no raw
//     SF Symbol call beyond scripts/icons/native-symbols-baseline.json (scripts/icons/check_native_symbols.py).
//     Baselines may only shrink: a count that drops must be lowered in the same PR,
//     `UPDATE_ICON_REGISTRY_BASELINE=1 bun test src/agent-session/acpmux/icons/iconRegistry.test.ts`
//     (web) or `python3 scripts/icons/check_native_symbols.py --update-baseline` (native); both refuse to grow.
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../../../../../", import.meta.url));
const SOURCE = join(repoRoot, "design/icons/source");
const WEB_SRC = join(repoRoot, "webviews/src");
const ICONS_MODULE = "agent-session/acpmux/icons/";
const BASELINE = fileURLToPath(new URL("./iconRegistryBaseline.json", import.meta.url));

// MARK: (a) the registry follows SPEC.md

interface SourceIcon {
  name: string;
  line: string;
  solid: string;
  cat?: string | null;
  alts?: { label?: string; line?: string; solid?: string; cat?: string | null }[];
  source?: string;
}

const icons: SourceIcon[] = readdirSync(SOURCE)
  .filter((file) => file.endsWith(".json"))
  .sort()
  .flatMap((file) => (JSON.parse(readFileSync(join(SOURCE, file), "utf8")) as { icons: SourceIcon[] }).icons);

type Kind = "line" | "solid" | "cat";
interface Drawing {
  icon: string;
  /// "line", "solid", "cat", "alt1.line", ...
  where: string;
  kind: Kind;
  svg: string;
  vendored: boolean;
}

function drawings(): Drawing[] {
  const out: Drawing[] = [];
  for (const icon of icons) {
    const vendored = icon.source === "chromium";
    const add = (where: string, kind: Kind, svg: string | null | undefined) => {
      if (svg) out.push({ icon: icon.name, where, kind, svg, vendored });
    };
    add("line", "line", icon.line);
    add("solid", "solid", icon.solid);
    add("cat", "cat", icon.cat);
    (icon.alts ?? []).forEach((alt, i) => {
      add(`alt${i}.line`, "line", alt.line);
      add(`alt${i}.solid`, "solid", alt.solid);
      add(`alt${i}.cat`, "cat", alt.cat);
    });
  }
  return out;
}

const TAG = /<(\/?)([a-zA-Z][\w:-]*)((?:\s+[\w:-]+\s*=\s*(?:'[^']*'|"[^"]*"))*)\s*(\/?)>/g;
const ATTR = /([\w:-]+)\s*=\s*(?:'([^']*)'|"([^"]*)")/g;
const SHAPES = new Set(["path", "circle", "rect", "line", "polyline", "polygon", "ellipse"]);
const PAINT = ["fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "class"];
const GEOMETRY = ["d", "cx", "cy", "r", "rx", "ry", "x", "y", "width", "height", "x1", "y1", "x2", "y2", "points"];

interface Shape {
  /// Inherited presentation attributes, as build_pack.py's walk() resolves them.
  paint: Record<string, string>;
  /// Stroke width in grid units: stroke-width times the transforms' scale.
  width: number;
  /// Inside <defs>/<mask>: a knockout, not ink.
  knockout: boolean;
  /// The element and its geometry attributes, to compare a Solid with its Line.
  geometry: string;
}

function transformScale(text: string | undefined): number {
  let scale = 1;
  for (const [, name, args] of (text ?? "").matchAll(/(\w+)\s*\(([^)]*)\)/g)) {
    const v = args
      .split(/[\s,]+/)
      .filter(Boolean)
      .map(Number);
    if (name === "scale") scale *= Math.sqrt(Math.abs(v[0] * (v[1] ?? v[0])));
    else if (name === "matrix") scale *= Math.sqrt(Math.abs(v[0] * v[3] - v[1] * v[2]));
  }
  return scale;
}

function parse(svg: string): { root: Record<string, string>; shapes: Shape[]; masks: string[] } {
  const stack: { tag: string; paint: Record<string, string>; scale: number; transform: string }[] = [];
  let root: Record<string, string> = {};
  const shapes: Shape[] = [];
  const masks: string[] = [];
  for (const [, close, tag, attrs, self] of svg.matchAll(TAG)) {
    if (close) {
      stack.pop();
      continue;
    }
    const own: Record<string, string> = {};
    for (const a of attrs.matchAll(ATTR)) own[a[1]] = a[2] ?? a[3];
    if (tag === "svg") root = own;
    if (tag === "mask" && own.id) masks.push(own.id);
    const parent = stack.at(-1);
    const paint = { ...(parent?.paint ?? { fill: "black" }) };
    for (const key of PAINT) if (key in own) paint[key] = own[key];
    const scale = (parent?.scale ?? 1) * transformScale(own.transform);
    if (SHAPES.has(tag))
      shapes.push({
        paint,
        width: Number(paint["stroke-width"] ?? 1) * scale,
        knockout: stack.some((s) => s.tag === "defs" || s.tag === "mask"),
        geometry: [
          tag,
          ...GEOMETRY.map((key) => own[key] ?? ""),
          ...[...stack.map((s) => s.transform), own.transform ?? ""].filter(Boolean),
        ].join("|"),
      });
    if (!self) stack.push({ tag, paint, scale, transform: own.transform ?? "" });
  }
  return { root, shapes, masks };
}

const none = (paint: string | undefined): paint is undefined | "none" => paint === undefined || paint === "none";
const INK = new Set(["currentColor"]);
const CAT_INK = new Set(["currentColor", "var(--accent)"]);

/// What a drawing breaks, as short tags: "w1.875" (a stroke width), "cap", "join", "paint" (stroke not
/// ink), "fill" (fill not ink: an unset fill is SVG's black), "open-solid" (a Solid with no fill that is
/// not its Line's drawing at 2).
function violations(d: Drawing, line: string | undefined): string[] {
  const { shapes, masks } = parse(d.svg);
  const visible = shapes.filter((shape) => !shape.knockout);
  const found = new Set<string>();
  const ink = d.kind === "cat" ? CAT_INK : INK;
  const filled = visible.some((shape) => !none(shape.paint.fill));
  // SPEC: "Open shapes with no interior (arrows, chevrons, x, plus) stay identical to Line but at
  // stroke-width 2."
  const open = d.kind === "solid" && !filled && masks.length === 0;
  for (const { paint, width } of visible) {
    if (!none(paint.fill) && !ink.has(paint.fill)) found.add("fill");
    if (none(paint.stroke)) continue;
    if (!ink.has(paint.stroke)) found.add("paint");
    const w = Math.round(width * 1000) / 1000;
    const allowed = d.kind !== "solid" ? [1.5] : open ? [2] : [1.5, 2];
    if (!allowed.includes(w)) found.add(`w${w}`);
    // Line and Cat strokes are all round; a Solid's open strokes (2) keep round caps. A silhouette's
    // 1.5 outline only rounds its fill's edge, so its caps and joins do not show.
    if (d.kind !== "solid" || w === 2) if (paint["stroke-linecap"] !== "round") found.add("cap");
    if (d.kind !== "solid") if (paint["stroke-linejoin"] !== "round") found.add("join");
  }
  if (open && line) {
    const geometry = (svg: string) =>
      parse(svg)
        .shapes.filter((shape) => !shape.knockout)
        .map((shape) => shape.geometry);
    if (JSON.stringify(geometry(d.svg)) !== JSON.stringify(geometry(line))) found.add("open-solid");
  }
  return [...found].sort();
}

// Drawings that break the rules above, by "icon where", with what they break and why. Each must still
// exist and still break exactly what is listed, so a fixed drawing leaves this list in the same PR.
const TRANSCRIPT_16 =
  "transcript batch drawn on a 16 grid at stroke 1.25 and scaled 1.5 (stroke 1.875); redraw on the 24 grid";
const UNFILLED_SLASH =
  "the Solid's slash is a line with no fill='none', so it inherits SVG's black fill; a line encloses nothing, so nothing draws";
const WIDGET_175 =
  "widget SF Symbol solid (weather, time, calendar) drawn at stroke 1.75 for the scene renderer; redraw at 1.5 or 2";
const ALTERNATE = "an alternate the gallery compares, not the shipped drawing";
const EXCEPTIONS: Record<string, { breaks: string[]; reason: string }> = {
  ...Object.fromEntries(
    [
      "action.quote",
      "action.retry",
      "action.save",
      "agent.bot",
      "agent.paused",
      "media.stop.circle",
      "message.delivered",
      "message.send",
      "nav.down",
      "permission.ask",
      "permission.auto",
      "permission.checked",
      "permission.full-access",
      "permission.shield",
      "sources.connected",
      "status.failure",
      "time.waiting",
      "tool.multiple",
      "tool.thought",
      "transcript.summary",
      "view.expand",
      "view.tab.trailing",
    ].flatMap((name) => [
      [`${name} line`, { breaks: ["w1.875"], reason: TRANSCRIPT_16 }],
      [`${name} solid`, { breaks: ["w1.875"], reason: TRANSCRIPT_16 }],
    ]),
  ),
  ...Object.fromEntries(
    [
      "action.hide",
      "site.permission.camera.blocked",
      "site.permission.insecurecontent.blocked",
      "site.permission.location.blocked",
      "site.permission.microphone.blocked",
      "site.permission.notifications.blocked",
      "site.permission.sound.blocked",
    ].map((name) => [`${name} solid`, { breaks: ["fill"], reason: UNFILLED_SLASH }]),
  ),
  ...Object.fromEntries(
    [
      "alarm",
      "calendar",
      "calendar.clock",
      "weather.cloud.bolt",
      "weather.cloud.bolt.rain",
      "weather.cloud.drizzle",
      "weather.cloud.fog",
      "weather.cloud.heavyrain",
      "weather.cloud.rain",
      "weather.cloud.sleet",
      "weather.cloud.sun",
      "weather.sunrise",
      "weather.sunset",
    ].map((name) => [`${name} solid`, { breaks: ["w1.75"], reason: WIDGET_175 }]),
  ),
  "prompt.save solid": {
    breaks: ["w1.5"],
    reason: "open Solid (lines and a plus) kept at the Line's 1.5, not the spec's 2; redraw at 2",
  },
  "security.insecure alt0.solid": { breaks: ["fill"], reason: `${UNFILLED_SLASH}; ${ALTERNATE}` },
  "status.progress line": { breaks: ["w3.5"], reason: "the progress arc is a thick band over the 1.5 ring" },
  "status.progress solid": { breaks: ["w4"], reason: "the progress arc is a thick band over the 2 ring" },
  "task.status.backlog line": {
    breaks: ["w1.75"],
    reason: "dotted ring: round dots of a 1.5 dash read faint at 12 px",
  },
  "task.status.backlog solid": { breaks: ["w2.5"], reason: "dotted ring, heavier dots for the selected state" },
  "task.status.triage line": {
    breaks: ["w1.302"],
    reason: "dashed ring scaled 0.868 to the status-circle size (SPEC)",
  },
  "task.status.triage solid": {
    breaks: ["w1.736"],
    reason: "dashed ring scaled 0.868 to the status-circle size (SPEC)",
  },
  "status.check solid": { breaks: ["w1.85"], reason: "bare check optically matched to the filled status marks" },
  "tool.search solid": { breaks: ["w2.5"], reason: "filled lens; the handle is thickened to balance the disc" },
  "mode.build solid": { breaks: ["w2.25"], reason: "hammer handle weighted against the filled head" },
  "context.usage alt1.line": { breaks: ["w1"], reason: `a thin tick inside the meter frame; ${ALTERNATE}` },
  "status.inprogress alt1.line": { breaks: ["w2"], reason: ALTERNATE },
  "status.inprogress alt1.solid": { breaks: ["w2.5"], reason: ALTERNATE },
  "agent.handoff alt0.solid": { breaks: ["w1.75"], reason: ALTERNATE },
  "agent.handoff alt1.solid": { breaks: ["w2.5"], reason: ALTERNATE },
};

// Solid masks not named cmxs-<icon>, with why.
const MASK_EXCEPTIONS: Record<string, string> = {
  "tunable.hover": "named cmxl-tunable-hover-s by the tunables batch; unique, but off the cmxs- scheme",
};

describe("icon registry follows SPEC.md", () => {
  const all = drawings();

  test("reads every source batch", () => {
    expect(icons.length).toBeGreaterThan(300);
    expect(new Set(icons.map((icon) => icon.name)).size).toBe(icons.length);
  });

  test("every drawing, vendored ones included, is on the 0 0 24 24 grid", () => {
    const off = all.filter((d) => parse(d.svg).root.viewBox !== "0 0 24 24");
    expect(off.map((d) => `${d.icon} ${d.where}: ${parse(d.svg).root.viewBox}`)).toEqual([]);
  });

  test("Line, Cat and Solid strokes follow the spec, or are a named exception", () => {
    const actual: Record<string, string[]> = {};
    for (const d of all) {
      if (d.vendored) continue;
      const line = d.where.endsWith("solid")
        ? all.find((x) => x.icon === d.icon && x.where === d.where.replace("solid", "line"))?.svg
        : undefined;
      const broken = violations(d, line);
      if (broken.length) actual[`${d.icon} ${d.where}`] = broken;
    }
    const expected = Object.fromEntries(Object.entries(EXCEPTIONS).map(([key, e]) => [key, [...e.breaks].sort()]));
    expect(actual).toEqual(expected);
  });

  test("every named exception still exists and says why", () => {
    const keys = new Set(all.map((d) => `${d.icon} ${d.where}`));
    for (const [key, e] of Object.entries(EXCEPTIONS)) {
      expect(keys.has(key)).toBe(true);
      expect(e.reason.length).toBeGreaterThan(0);
    }
  });

  test("Solid masks are named cmxs-<icon> and no two icons share one", () => {
    const owner = new Map<string, string>();
    const wrong: string[] = [];
    for (const d of all) {
      if (d.kind !== "solid" || d.vendored) continue;
      for (const id of parse(d.svg).masks) {
        if (!id.startsWith(`cmxs-${d.icon.replaceAll(".", "-")}`) && !Object.hasOwn(MASK_EXCEPTIONS, d.icon))
          wrong.push(`${d.icon} ${d.where}: ${id}`);
        if (owner.has(id) && owner.get(id) !== d.icon) wrong.push(`${id}: ${owner.get(id)} and ${d.icon}`);
        owner.set(id, d.icon);
      }
    }
    expect(wrong).toEqual([]);
    for (const name of Object.keys(MASK_EXCEPTIONS)) {
      const solid = all.find((d) => d.icon === name && d.where === "solid");
      expect(solid && parse(solid.svg).masks.some((id) => !id.startsWith(`cmxs-${name.replaceAll(".", "-")}`))).toBe(
        true,
      );
    }
  });
});

// MARK: (b) nothing outside the registry draws its own icon

// Icon libraries the web UI must not import: icons come from the pack (<Icon name=...>).
const ICON_LIBRARY =
  /(?:from\s+|import\s*\(\s*|require\s*\(\s*)["'](?:lucide-react|lucide|@radix-ui\/react-icons|@phosphor-icons\/[\w-]+|phosphor-react|@tabler\/icons(?:-react)?|@heroicons\/[\w/-]+|react-icons(?:\/[\w-]+)?|@fortawesome\/[\w-]+|@iconify\/[\w-]+|@mui\/icons-material(?:\/[\w-]+)?|feather-icons|react-feather|@primer\/octicons-react|octicons)["']/;
const INLINE_SVG = /<svg[\s>]/g;

function webSources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "node_modules" ? [] : webSources(path);
    return /\.(?:tsx?|jsx?|mjs)$/.test(entry.name) && !/\.test\.[jt]sx?$/.test(entry.name) ? [path] : [];
  });
}

function webScan() {
  const svg: Record<string, number> = {};
  const libraries: string[] = [];
  for (const path of webSources(WEB_SRC)) {
    const file = relative(WEB_SRC, path).replaceAll("\\", "/");
    if (file.startsWith(ICONS_MODULE)) continue;
    const text = readFileSync(path, "utf8");
    if (ICON_LIBRARY.test(text)) libraries.push(file);
    const n = text.match(INLINE_SVG)?.length ?? 0;
    if (n) svg[file] = n;
  }
  return { svg, libraries };
}

type Baseline = { inlineSvg: Record<string, number> };

describe("one icon registry", () => {
  test("webviews depends on no icon library", () => {
    const pkg = JSON.parse(readFileSync(join(repoRoot, "webviews/package.json"), "utf8"));
    const deps = Object.keys({ ...pkg.dependencies, ...pkg.devDependencies });
    expect(deps.filter((dep) => ICON_LIBRARY.test(`from "${dep}"`))).toEqual([]);
  });

  test("web code outside the icons module imports no icon library and adds no inline <svg>", () => {
    const { svg, libraries } = webScan();
    expect(libraries).toEqual([]);
    const base = JSON.parse(readFileSync(BASELINE, "utf8")) as Baseline;
    if (process.env.UPDATE_ICON_REGISTRY_BASELINE === "1") {
      const grew = Object.entries(svg).filter(([file, n]) => n > (base.inlineSvg[file] ?? 0));
      expect(grew).toEqual([]);
      writeFileSync(
        BASELINE,
        `${JSON.stringify({ inlineSvg: Object.fromEntries(Object.entries(svg).sort(([a], [b]) => a.localeCompare(b))) }, null, 1)}\n`,
      );
      return;
    }
    const problems: string[] = [];
    for (const [file, n] of Object.entries(svg))
      if (n > (base.inlineSvg[file] ?? 0))
        problems.push(
          `${file}: ${n} inline <svg> (baseline ${base.inlineSvg[file] ?? 0}); draw a pack <Icon name=...>`,
        );
    for (const [file, allowed] of Object.entries(base.inlineSvg))
      if ((svg[file] ?? 0) < allowed)
        problems.push(
          `${file}: ${svg[file] ?? 0} inline <svg>, baseline ${allowed}; lower the baseline (see the header)`,
        );
    expect(problems).toEqual([]);
  });

  test("native code adds no raw SF Symbol call (scripts/icons/check_native_symbols.py)", () => {
    const run = Bun.spawnSync(["python3", "-I", "scripts/icons/check_native_symbols.py"], { cwd: repoRoot });
    expect(run.stderr.toString() + run.stdout.toString()).toBe("");
    expect(run.exitCode).toBe(0);
  }, 60_000);
});
