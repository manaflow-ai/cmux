#!/usr/bin/env bun
// The visual expectation gate: compares a PR's captures with the checked-in baselines, judges each
// changed state against its surface's tolerance, keep regions and the PR body's justification, and
// writes the review page (comment.md with before | after | diff per changed state, next to the
// justification) plus report.json. Exit 1 when a keep region changed without a justification or a
// baselined state stopped rendering; unexplained changes elsewhere only warn.
//
//   bun gate.ts --expectations BASE/design/visual-expectations --baselines BASE/design/visual-expectations/baselines \
//     --captures CAPTURES --body body.md --out OUT [--head-expectations HEAD/design/visual-expectations]
//     [--pr N --head-sha SHA --base-sha SHA --media-base URL] [--update BASELINES_DIR]
//
// CAPTURES and baselines share one layout: <platform>/<surface>/<state>-<scheme>.png, a sidecar
// <state>-<scheme>.json ({keep: [{name, box}], nondeterministic?, error?}) and <platform>/renderer.json.
// Judging uses the base's expectations, so a PR cannot loosen its own keep regions; a PR that edits
// expectations is listed for say-so.
import { PNG } from "pngjs";
import pixelmatch from "pixelmatch";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { changedBoxes, type Box } from "../compare";
import { keepFor, loadSurfaces, shotPath, surfaceRef, type Platform, type Scheme, type Surface } from "./expectations";
import { justificationFor, parseJustifications, type Justification, type Verdict } from "./justification";

export type Status = "unchanged" | "within" | "changed" | "new" | "missing" | "flaky";
export type Severity = "ok" | "explained" | "warn" | "fail";
export type KeepHit = { name: string; why: string; pixels: number };
export type SchemeResult = {
  scheme: Scheme;
  status: Status;
  pixels: number;
  ratio: number;
  boxes: Box[];
  keepHits: KeepHit[];
  width: number;
  height: number;
  error?: string;
};
export type StateResult = {
  ref: string;
  surface: string;
  platform: Platform;
  title: string;
  spec?: string;
  state: string;
  status: Status;
  severity: Severity;
  why: string;
  justification?: Justification;
  schemes: SchemeResult[];
  image?: string;
};
export type Report = {
  pr?: number;
  head?: string;
  base?: string;
  verdict: "pass" | "warn" | "fail";
  counts: Record<Severity, number> & { unchanged: number };
  results: StateResult[];
  notCaptured: string[];
  rendererChanged: { platform: Platform; base: string; head: string }[];
  expectationsChanged: string[];
  unusedJustifications: Justification[];
  justificationProblems: string[];
};

type Sidecar = { keep?: { name: string; box: [number, number, number, number] }[]; nondeterministic?: boolean; error?: string };

const readJson = <T>(file: string): T | undefined => (existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as T) : undefined);
const sidecarOf = (png: string) => readJson<Sidecar>(png.replace(/\.png$/, ".json")) ?? {};
const readPng = (file: string) => PNG.sync.read(readFileSync(file));
const renderer = (root: string, platform: Platform) =>
  readJson<{ id?: string }>(join(root, platform, "renderer.json"))?.id ?? "";

function pad(png: PNG, width: number, height: number): Buffer {
  if (png.width === width && png.height === height) return png.data;
  const out = Buffer.alloc(width * height * 4);
  for (let y = 0; y < png.height; y++) png.data.copy(out, y * width * 4, y * png.width * 4, (y + 1) * png.width * 4);
  return out;
}

/** One flag per differing pixel at the surface's colour threshold; a size change counts the uncovered area. */
export function diff(a: PNG, b: PNG, threshold: number) {
  const width = Math.max(a.width, b.width);
  const height = Math.max(a.height, b.height);
  const output = Buffer.alloc(width * height * 4);
  pixelmatch(pad(a, width, height), pad(b, width, height), output, width, height, {
    threshold,
    includeAA: true,
    diffMask: true,
  });
  const mask = new Uint8Array(width * height);
  let pixels = 0;
  for (let i = 0; i < mask.length; i++)
    if (output[i * 4 + 3]! > 0) {
      mask[i] = 1;
      pixels++;
    }
  return { mask, width, height, pixels };
}

/** Changed pixels inside each keep box (boxes in the image's pixels). */
export function keepHits(mask: Uint8Array, width: number, height: number, regions: { name: string; why: string; box: number[] }[]): KeepHit[] {
  const hits: KeepHit[] = [];
  for (const r of regions) {
    const [x0, y0, w, h] = r.box.map(Math.round) as [number, number, number, number];
    let pixels = 0;
    for (let y = Math.max(0, y0); y < Math.min(height, y0 + h); y++)
      for (let x = Math.max(0, x0); x < Math.min(width, x0 + w); x++) pixels += mask[y * width + x]!;
    if (pixels) hits.push({ name: r.name, why: r.why, pixels });
  }
  return hits;
}

/** The keep boxes for one shot: fixed boxes from the expectation, selector boxes from the capture sidecars (head, else base). */
function keepBoxes(surface: Surface, state: string, scale: number, head: Sidecar, base: Sidecar) {
  const capture = surface.captures.find((c) => c.state === state)!;
  const boxes: { name: string; why: string; box: number[] }[] = [];
  for (const region of keepFor(surface, capture)) {
    if (region.box) boxes.push({ name: region.name, why: region.why, box: region.box.map((n) => n * scale) });
    else
      for (const found of [...(head.keep ?? []), ...(base.keep ?? [])].filter((k) => k.name === region.name))
        boxes.push({ name: region.name, why: region.why, box: found.box });
  }
  return boxes;
}

const RED = [235, 40, 40];
const KEEP = [255, 196, 0];

/** The after picture dimmed to grey, changed pixels red, keep regions outlined in amber. */
export function heatmap(head: PNG, mask: Uint8Array, width: number, height: number, keep: { box: number[] }[]): PNG {
  const out = new PNG({ width, height });
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 4;
      const inside = x < head.width && y < head.height;
      const i = (y * head.width + x) * 4;
      const grey = inside ? Math.round((head.data[i]! * 0.3 + head.data[i + 1]! * 0.59 + head.data[i + 2]! * 0.11) * 0.35 + 40) : 20;
      const [r, g, b] = mask[y * width + x] ? RED : [grey, grey, grey];
      out.data[o] = r!;
      out.data[o + 1] = g!;
      out.data[o + 2] = b!;
      out.data[o + 3] = 255;
    }
  for (const { box } of keep) {
    const [x0, y0, w, h] = box.map(Math.round) as [number, number, number, number];
    for (let t = 0; t < 2; t++)
      for (let x = x0; x < x0 + w; x++)
        for (const y of [y0 + t, y0 + h - 1 - t]) paint(out, x, y, KEEP);
    for (let t = 0; t < 2; t++)
      for (let y = y0; y < y0 + h; y++)
        for (const x of [x0 + t, x0 + w - 1 - t]) paint(out, x, y, KEEP);
  }
  return out;
}

function paint(png: PNG, x: number, y: number, [r, g, b]: number[]) {
  if (x < 0 || y < 0 || x >= png.width || y >= png.height) return;
  const o = (y * png.width + x) * 4;
  [png.data[o], png.data[o + 1], png.data[o + 2], png.data[o + 3]] = [r!, g!, b!, 255];
}

const GAP = 12;
const MAX_WIDTH = 3000;

/** One review image per state: a row per scheme, before | after | diff. A missing side is left blank. */
export function reviewSheet(rows: (PNG | undefined)[][]): PNG {
  const cellW = Math.max(1, ...rows.flat().map((p) => p?.width ?? 0));
  const rowH = rows.map((row) => Math.max(1, ...row.map((p) => p?.height ?? 0)));
  let out = new PNG({ width: cellW * 3 + GAP * 4, height: rowH.reduce((a, b) => a + b, 0) + GAP * (rows.length + 1) });
  for (let i = 0; i < out.data.length; i += 4) [out.data[i], out.data[i + 1], out.data[i + 2], out.data[i + 3]] = [128, 128, 128, 255];
  let top = GAP;
  rows.forEach((row, r) => {
    row.forEach((png, c) => {
      if (!png) return;
      const left = GAP + c * (cellW + GAP);
      for (let y = 0; y < png.height; y++) png.data.copy(out.data, ((top + y) * out.width + left) * 4, y * png.width * 4, (y + 1) * png.width * 4);
    });
    top += rowH[r]! + GAP;
  });
  while (out.width > MAX_WIDTH) out = halve(out);
  return out;
}

function halve(png: PNG): PNG {
  const width = Math.floor(png.width / 2);
  const height = Math.floor(png.height / 2);
  const out = new PNG({ width, height });
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++)
      for (let c = 0; c < 4; c++) {
        const at = (dx: number, dy: number) => png.data[((y * 2 + dy) * png.width + x * 2 + dx) * 4 + c]!;
        out.data[(y * width + x) * 4 + c] = Math.round((at(0, 0) + at(1, 0) + at(0, 1) + at(1, 1)) / 4);
      }
  return out;
}

const STATUS_RANK: Status[] = ["missing", "changed", "new", "flaky", "within", "unchanged"];
const SEVERITY_RANK: Severity[] = ["fail", "warn", "explained", "ok"];

/** The severity of one state, from its worst scheme and its justification. */
export function judge(status: Status, keepHit: boolean, justification: Justification | undefined, rendererChanged: boolean): { severity: Severity; why: string } {
  if (status === "unchanged" || status === "within") return { severity: "ok", why: status === "within" ? "within tolerance" : "unchanged" };
  if (status === "flaky") return { severity: "warn", why: "the head renders differently twice: a clock, font or fixture leak, not judged" };
  if (justification) {
    if (status === "missing" && justification.verdict !== "removed")
      return { severity: "fail", why: `no longer renders; the justification says ${justification.verdict}, not removed` };
    return { severity: "explained", why: justification.verdict === "worse" ? "explained, and called worse" : "explained" };
  }
  if (status === "missing") return { severity: "fail", why: "had a baseline and no longer renders, with no justification" };
  if (status === "new") return { severity: "warn", why: "new state with no baseline and no justification" };
  if (rendererChanged) return { severity: "warn", why: "changed, but the renderer differs from the baselines' (refresh them)" };
  if (keepHit) return { severity: "fail", why: "a keep region changed with no justification" };
  return { severity: "warn", why: "changed with no justification" };
}

export type GateInput = {
  expectations: string;
  headExpectations?: string;
  baselines: string;
  captures: string;
  body: string;
  out: string;
  pr?: number;
  head?: string;
  base?: string;
  mediaBase?: string;
};

export function runGate(input: GateInput): Report {
  const surfaces = loadSurfaces(input.expectations);
  const headSurfaces = input.headExpectations ? loadSurfaces(input.headExpectations) : surfaces;
  // Judge with the base's rules; a surface only the head declares is judged by its own until it lands.
  const byRef = new Map(surfaces.map((s) => [surfaceRef(s), s]));
  for (const s of headSurfaces) if (!byRef.has(surfaceRef(s))) byRef.set(surfaceRef(s), s);
  const expectationsChanged = headSurfaces
    .filter((h) => {
      const b = surfaces.find((s) => surfaceRef(s) === surfaceRef(h));
      return !b || JSON.stringify(b) !== JSON.stringify(h);
    })
    .map(surfaceRef)
    .concat(surfaces.filter((b) => !headSurfaces.some((h) => surfaceRef(h) === surfaceRef(b))).map((b) => `${surfaceRef(b)} (removed)`));
  const { justifications, problems } = parseJustifications(input.body);
  const used = new Set<Justification>();
  const platforms = [...new Set([...byRef.values()].map((s) => s.platform))];
  const captured = new Set(platforms.filter((p) => existsSync(join(input.captures, p))));
  const rendererChanged = [...captured]
    .map((platform) => ({ platform, base: renderer(input.baselines, platform), head: renderer(input.captures, platform) }))
    .filter((r) => r.base && r.head && r.base !== r.head);
  mkdirSync(join(input.out, "images"), { recursive: true });
  const results: StateResult[] = [];
  const notCaptured: string[] = [];
  for (const surface of byRef.values()) {
    // A surface the run did not attempt (another platform, or a --surfaces subset) has no folder; a
    // state it attempted and failed has a sidecar with its error, and is judged.
    if (!captured.has(surface.platform) || !existsSync(join(input.captures, surface.platform, surface.id))) {
      notCaptured.push(surfaceRef(surface));
      continue;
    }
    const ref = surfaceRef(surface);
    for (const capture of surface.captures) {
      const rows: (PNG | undefined)[][] = [];
      const schemes: SchemeResult[] = [];
      for (const scheme of surface.schemes) {
        const basePath = shotPath(input.baselines, surface, capture.state, scheme);
        const headPath = shotPath(input.captures, surface, capture.state, scheme);
        const head = existsSync(headPath) ? sidecarOf(headPath) : {};
        const base = existsSync(basePath) ? sidecarOf(basePath) : {};
        const result: SchemeResult = { scheme, status: "unchanged", pixels: 0, ratio: 0, boxes: [], keepHits: [], width: 0, height: 0 };
        schemes.push(result);
        const headPng = existsSync(headPath) && !head.error ? readPng(headPath) : undefined;
        const basePng = existsSync(basePath) ? readPng(basePath) : undefined;
        if (!headPng) {
          result.status = basePng ? "missing" : "new";
          result.error = head.error ?? "not captured";
          if (basePng) rows.push([basePng, undefined, undefined]);
          continue;
        }
        [result.width, result.height] = [headPng.width, headPng.height];
        if (head.nondeterministic) {
          result.status = "flaky";
          continue;
        }
        if (!basePng) {
          result.status = "new";
          rows.push([undefined, headPng, undefined]);
          continue;
        }
        const d = diff(basePng, headPng, surface.tolerance.threshold);
        [result.width, result.height, result.pixels, result.ratio] = [d.width, d.height, d.pixels, d.pixels / (d.width * d.height)];
        if (!d.pixels) continue;
        // Pictures are at device scale; fixed keep boxes are in CSS px / points.
        const scale = Number((head as { scale?: number }).scale ?? 1);
        const keep = keepBoxes(surface, capture.state, scale, head, base);
        result.keepHits = keepHits(d.mask, d.width, d.height, keep);
        result.boxes = changedBoxes(d.mask, d.width, d.height);
        // Anything in a keep region counts, whatever the tolerance: that is what "keep" means.
        result.status = result.ratio <= surface.tolerance.ratio && !result.keepHits.length ? "within" : "changed";
        if (result.status === "changed") rows.push([basePng, headPng, heatmap(headPng, d.mask, d.width, d.height, keep)]);
      }
      const status = schemes.map((s) => s.status).sort((a, b) => STATUS_RANK.indexOf(a) - STATUS_RANK.indexOf(b))[0]!;
      const justification = justificationFor(justifications, ref, capture.state);
      if (justification && status !== "unchanged" && status !== "within") used.add(justification);
      const keepHit = schemes.some((s) => s.keepHits.length > 0);
      const changedRenderer = rendererChanged.some((r) => r.platform === surface.platform);
      const { severity, why } = judge(status, keepHit, justification, changedRenderer);
      const result: StateResult = {
        ref,
        surface: surface.id,
        platform: surface.platform,
        title: surface.title,
        spec: surface.spec,
        state: capture.state,
        status,
        severity,
        why,
        justification: status === "unchanged" || status === "within" ? undefined : justification,
        schemes,
      };
      if (rows.length) {
        result.image = `vg-${(input.head ?? "head").slice(0, 7)}-${surface.platform}-${surface.id}-${capture.state}.png`;
        writeFileSync(join(input.out, "images", result.image), PNG.sync.write(reviewSheet(rows)));
      }
      results.push(result);
    }
  }
  results.sort(
    (a, b) =>
      SEVERITY_RANK.indexOf(a.severity) - SEVERITY_RANK.indexOf(b.severity) ||
      STATUS_RANK.indexOf(a.status) - STATUS_RANK.indexOf(b.status) ||
      a.ref.localeCompare(b.ref) ||
      a.state.localeCompare(b.state),
  );
  const count = (s: Severity) => results.filter((r) => r.severity === s).length;
  const counts = {
    fail: count("fail"),
    warn: count("warn") + (expectationsChanged.length && input.headExpectations ? 1 : 0),
    explained: count("explained"),
    ok: count("ok"),
    unchanged: results.filter((r) => r.status === "unchanged").length,
  };
  const report: Report = {
    pr: input.pr,
    head: input.head,
    base: input.base,
    verdict: counts.fail ? "fail" : counts.warn ? "warn" : "pass",
    counts,
    results,
    notCaptured,
    rendererChanged,
    expectationsChanged: input.headExpectations ? expectationsChanged : [],
    unusedJustifications: justifications.filter((j) => !used.has(j)),
    justificationProblems: problems,
  };
  writeFileSync(join(input.out, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
  writeFileSync(join(input.out, "comment.md"), commentMarkdown(report, input.mediaBase));
  writeFileSync(join(input.out, "media.txt"), results.flatMap((r) => (r.image ? [`images/${r.image}\n`] : [])).join(""));
  return report;
}

export const COMMENT_MARKER = "<!-- visual-expectation-gate -->";
const ICON: Record<Severity, string> = { fail: "❌", warn: "⚠️", explained: "✅", ok: "·" };
const VERDICT_WORD: Record<Verdict, string> = {
  better: "better",
  worse: "**worse**",
  intentional: "intentional",
  neutral: "neutral",
  removed: "removed",
};

const pct = (r: number) => `${(r * 100).toFixed(r < 0.001 ? 3 : 2)}%`;

/** The one PR comment: verdict line, then each changed state's before | after | diff with its justification. */
export function commentMarkdown(report: Report, mediaBase?: string): string {
  const lines = [COMMENT_MARKER];
  const head = report.head ? ` at \`${report.head.slice(0, 12)}\`` : "";
  const headline =
    report.verdict === "fail"
      ? "❌ **Visual gate: fails**"
      : report.verdict === "warn"
        ? "⚠️ **Visual gate: unexplained changes**"
        : "✅ **Visual gate: every change explained**";
  lines.push(
    `${headline}${head}: ${report.counts.fail} failing, ${report.counts.warn} unexplained, ${report.counts.explained} explained, ${report.counts.ok} within expectation.`,
    "",
  );
  if (report.verdict !== "pass")
    lines.push(
      "Explain each change in the PR body (the gate reads it on its next run):",
      "",
      "```md",
      "## Visual changes",
      ...report.results
        .filter((r) => r.severity === "fail" || r.severity === "warn")
        .slice(0, 8)
        .map((r) => `- ${r.ref}${report.results.filter((x) => x.ref === r.ref).length > 1 ?`#${r.state}` : ""}: better|worse|intentional|neutral|removed — why`),
      "```",
      "",
    );
  const shown = report.results.filter((r) => r.severity !== "ok");
  for (const r of shown) {
    const schemes = r.schemes
      .filter((s) => s.status !== "unchanged")
      .map((s) => `${s.scheme} ${s.status}${s.pixels ? ` ${pct(s.ratio)}` : ""}${s.keepHits.length ? `, keep: ${s.keepHits.map((k) => k.name).join(", ")}` : ""}`)
      .join("; ");
    lines.push(`#### ${ICON[r.severity]} \`${r.ref}\` · ${r.state}: ${r.title}`, "");
    lines.push(`${r.why}. ${schemes}${r.spec ? ` · spec: \`${r.spec}\`` : ""}`, "");
    if (r.justification) lines.push(`> **${VERDICT_WORD[r.justification.verdict]}**: ${r.justification.reason}`, "");
    for (const s of r.schemes) for (const k of s.keepHits) lines.push(`- keep \`${k.name}\` (${s.scheme}, ${k.pixels} px): ${k.why}`);
    if (r.schemes.some((s) => s.keepHits.length)) lines.push("");
    if (r.image)
      lines.push(
        mediaBase ? `before · after · diff (rows: ${r.schemes.filter((s) => s.status === "changed" || s.status === "new" || s.status === "missing").map((s) => s.scheme).join(", ")})` : "",
        mediaBase ? `![${r.ref} ${r.state}](${mediaBase.replace(/\/$/, "")}/${r.image})` : `image: \`${r.image}\` (in the run's artifact)`,
        "",
      );
  }
  if (report.unusedJustifications.length)
    lines.push(
      `Justified but unchanged (stale lines?): ${report.unusedJustifications.map((j) => `\`${j.ref}${j.state ? `#${j.state}` : ""}\``).join(", ")}`,
      "",
    );
  if (report.justificationProblems.length) lines.push("Unreadable justification lines:", ...report.justificationProblems.map((p) => `- ${p}`), "");
  if (report.expectationsChanged.length)
    lines.push(`⚠️ This PR edits the expectations of ${report.expectationsChanged.map((r) => `\`${r}\``).join(", ")}; they were judged by the base's.`, "");
  for (const r of report.rendererChanged) lines.push(`Renderer changed on ${r.platform}: \`${r.base}\` → \`${r.head}\`; changes there only warn until baselines are refreshed.`, "");
  if (report.notCaptured.length) lines.push(`Not captured on this run: ${report.notCaptured.map((r) => `\`${r}\``).join(", ")}.`, "");
  const unchanged = report.results.filter((r) => r.severity === "ok");
  if (unchanged.length)
    lines.push(
      `<details><summary>${unchanged.length} states within expectation</summary>`,
      "",
      ...unchanged.map((r) => `- \`${r.ref}\` · ${r.state}: ${r.why}`),
      "",
      "</details>",
      "",
    );
  const refresh = report.results.filter((r) => r.severity === "explained" && r.status !== "missing");
  if (refresh.length)
    lines.push(
      `Baselines to refresh with this PR (${refresh.length} states): \`bun scripts/gallery-matrix/expectations/gate.ts ... --update design/visual-expectations/baselines\` on the run's captures, or copy them from its \`captures/\` artifact.`,
      "",
    );
  lines.push("<sub>Visual expectation gate · `design/visual-expectations/README.md`</sub>");
  return `${lines.join("\n")}\n`;
}

/** Copies the head captures of every explained or new state into a baselines tree. */
export function updateBaselines(report: Report, captures: string, baselines: string): string[] {
  const written: string[] = [];
  for (const r of report.results) {
    if (!(r.severity === "explained" || r.status === "new") || r.status === "missing") continue;
    for (const s of r.schemes) {
      const surface = { platform: r.platform, id: r.surface };
      const from = shotPath(captures, surface, r.state, s.scheme);
      if (!existsSync(from)) continue;
      const to = shotPath(baselines, surface, r.state, s.scheme);
      mkdirSync(dirname(to), { recursive: true });
      copyFileSync(from, to);
      const sidecar = from.replace(/\.png$/, ".json");
      if (existsSync(sidecar)) copyFileSync(sidecar, to.replace(/\.png$/, ".json"));
      written.push(to);
    }
  }
  for (const platform of new Set(report.results.map((r) => r.platform))) {
    const from = join(captures, platform, "renderer.json");
    if (written.some((w) => w.startsWith(join(baselines, platform))) && existsSync(from)) copyFileSync(from, join(baselines, platform, "renderer.json"));
  }
  return written;
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: {
      expectations: { type: "string" },
      "head-expectations": { type: "string" },
      baselines: { type: "string" },
      captures: { type: "string" },
      body: { type: "string" },
      out: { type: "string" },
      pr: { type: "string" },
      "head-sha": { type: "string" },
      "base-sha": { type: "string" },
      "media-base": { type: "string" },
      update: { type: "string" },
    },
  });
  for (const name of ["expectations", "baselines", "captures", "out"] as const)
    if (!values[name]) throw new Error(`--${name} is required`);
  const report = runGate({
    expectations: values.expectations!,
    headExpectations: values["head-expectations"],
    baselines: values.baselines!,
    captures: values.captures!,
    body: values.body ? readFileSync(values.body, "utf8") : "",
    out: values.out!,
    pr: values.pr ? Number(values.pr) : undefined,
    head: values["head-sha"],
    base: values["base-sha"],
    mediaBase: values["media-base"],
  });
  if (values.update) for (const file of updateBaselines(report, values.captures!, values.update)) console.log(`baseline: ${file}`);
  console.log(
    `visual gate: ${report.verdict} (${report.counts.fail} failing, ${report.counts.warn} unexplained, ${report.counts.explained} explained, ${report.counts.ok} ok)`,
  );
  process.exit(report.verdict === "fail" ? 1 : 0);
}
