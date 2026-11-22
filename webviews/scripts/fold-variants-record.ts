#!/usr/bin/env bun
// Records the big Claude turn fold in each of its looks (turnEndFold.ts `TURN_END_LOOKS`) at real speed in
// headless Chrome, and measures each: the most any content in the view moves between two frames (px), the
// fold's length (ms), and the widest blank band the view opens while it plays (px, the "gash").
// Leo, 2026-11-22: "the big fold we do for claude is not good looking enough. it looks like a gash collapsing."
//
//   bun scripts/fold-variants-record.ts [--looks fade,tuck,...] [--out DIR] [--ffmpeg PATH] [--scenario replay]
//     [--fixture FILE.ndjson --end STEP --tag NAME] [--recaps fade,rise,...] [--subagents slide,swap,...]
//
// `--recaps` records the turn with its closing recap (scenario big-claude-recap) once per recap entrance
// (turnEndFold.ts `TURN_END_RECAPS`), on the first of `--looks`; `--subagents` the turn with a subagent
// in its work (big-claude-subagent) once per subagent fold (`TURN_END_SUBAGENTS`). Besides the numbers
// above, each run reports the anchor's drift (the row under the view's center before the fold: how far
// it lands from where it was, and its biggest inked step), the least ink moved content has on any frame
// (a row and its snapshot together: the "blink"), and, with a recap or a subagent, that row's own numbers.
//
// `--fixture` records a recorded chat from outside the repo (copied under node_modules/ for the dev server,
// never committed) up to the turn end at step `--end`; `--tag` names its clips fold-TAG-LOOK.mp4.
//
// The page is test/browser/fold-variants.html (the chat-sim big-claude-turn scenario, drawn by the real
// VirtualTranscript with motion on). Frames come from Chrome's screencast with their own timestamps, so the
// clip plays at real speed at 60 fps (ffmpeg). The numbers come from the page itself, every frame.
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import type { Page } from "playwright";

const args = process.argv.slice(2);
const value = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const webviews = path.resolve(import.meta.dir, "..");
const out = path.resolve(value("--out") ?? "/tmp/fold-variants");
const ffmpeg = value("--ffmpeg") ?? "ffmpeg";
const fixture = value("--fixture");
const end = value("--end") === undefined ? undefined : Number(value("--end"));
const tag = value("--tag");
const scenario = fixture
  ? `url:/node_modules/.fold-fixtures/${path.basename(fixture)}`
  : (value("--scenario") ?? "big-claude-turn");
const { TURN_END_LOOKS } = await import("../src/agent-session/acpmux/conversation/turnEndFold");
const looks = value("--looks")?.split(",") ?? [...TURN_END_LOOKS];
const recaps = value("--recaps")?.split(",");
const subagents = value("--subagents")?.split(",");
/// One recording: a look, and the recap entrance or subagent fold it plays with.
type Variant = { name: string; look: string; scenario: string; recap?: string; subagent?: string };
const variants: Variant[] = recaps
  ? recaps.map((recap) => ({ name: `recap-${recap}`, look: looks[0]!, scenario: "big-claude-recap", recap }))
  : subagents
    ? subagents.map((subagent) => ({
        name: `subagent-${subagent}`,
        look: looks[0]!,
        scenario: "big-claude-subagent",
        subagent,
      }))
    : looks.map((look) => ({ name: look, look, scenario }));
const WIDTH = 720;
const HEIGHT = 640;

type Row = [key: string, top: number, height: number, ink: number, shownTop?: number, shownHeight?: number];
type Sample = { t: number; folding: boolean; view?: number; rows: Row[] };
type Run = { look: string; samples: Sample[]; startedAt: number };

/** The run's numbers: over the frames from the fold's start to when nothing moves any more. */
export function measure(run: Run) {
  const { samples } = run;
  const first = samples.findIndex((sample) => sample.folding);
  if (first < 0) return undefined;
  // Visible: drawn with some ink on both frames.
  const seen = (ink: number) => ink > 0.05;
  let maxJump = 0;
  let maxJumpRaw = 0;
  let lastChange = first;
  let worstAt = 0;
  for (let index = Math.max(1, first); index < samples.length; index += 1) {
    const before = new Map(samples[index - 1]!.rows.map((row) => [row[0], row]));
    let changed = false;
    for (const row of samples[index]!.rows) {
      const prior = before.get(row[0]);
      if (!prior) {
        if (seen(row[3])) changed = true;
        continue;
      }
      const jump = Math.abs(row[1] - prior[1]);
      if (jump > 0.25 || Math.abs(row[3] - prior[3]) > 0.01) changed = true;
      maxJumpRaw = Math.max(maxJumpRaw, jump);
      if (seen(row[3]) && seen(prior[3]) && jump > maxJump) {
        maxJump = jump;
        worstAt = samples[index]!.t - samples[first]!.t;
      }
    }
    if (samples[index - 1]!.rows.some((row) => seen(row[3]) && !samples[index]!.rows.some((r) => r[0] === row[0])))
      changed = true;
    if (changed) lastChange = index;
  }
  // The widest blank band between inked boxes, past the band at rest (the last frame's).
  const band = (sample: Sample) => {
    const boxes = sample.rows
      .filter((row) => row[3] > 0.15)
      .map((row) => [row[4] ?? row[1], (row[4] ?? row[1]) + (row[5] ?? row[2])] as const)
      .sort((a, b) => a[0] - b[0]);
    let widest = 0;
    let reach = boxes[0]?.[1] ?? 0;
    for (const [top, bottom] of boxes.slice(1)) {
      widest = Math.max(widest, top - reach);
      reach = Math.max(reach, bottom);
    }
    return widest;
  };
  const rest = band(samples.at(-1)!);
  let gash = 0;
  for (let index = first; index <= lastChange; index += 1) gash = Math.max(gash, band(samples[index]!) - rest);
  const round = (value: number) => Math.round(value * 10) / 10;
  // The rows that moved: drawn before the fold and at rest, at another top, and drawn on the fold's first
  // frame (a row the swap brought in under a kept id, the edits card, is new, not moved). Their ink on
  // each frame is the row's and its snapshot's (`snap:ID`) together, as two layers of paint.
  const before = samples[Math.max(0, first - 1)]!;
  const atRest = new Map(samples.at(-1)!.rows.map((row) => [row[0], row]));
  const inkOf = (sample: Sample, key: string) => {
    const own = sample.rows.find((row) => row[0] === key)?.[3] ?? 0;
    const snap = sample.rows.find((row) => row[0] === `snap:${key}`)?.[3] ?? 0;
    return 1 - (1 - own) * (1 - snap);
  };
  const moved = before.rows.filter(
    (row) =>
      !row[0].startsWith("snap:") &&
      !row[0].startsWith("ghost-") &&
      atRest.has(row[0]) &&
      Math.abs(atRest.get(row[0])![1] - row[1]) > 0.5 &&
      inkOf(samples[first]!, row[0]) > 0.5,
  );
  let minInk = 1;
  for (let index = first; index <= lastChange; index += 1) {
    const rows = new Map(samples[index]!.rows.map((row) => [row[0], row]));
    for (const row of moved) {
      const own = rows.get(row[0]);
      const snap = rows.get(`snap:${row[0]}`);
      if (!own && !snap) continue;
      const ink = 1 - (1 - (own?.[3] ?? 0)) * (1 - (snap?.[3] ?? 0));
      minInk = Math.min(minInk, ink);
    }
  }
  // The anchor: the row the fold keeps nearest the view's center before the fold (the row under it, when
  // the fold keeps that one).
  const center = (before.view ?? 0) / 2;
  const kept = before.rows.filter(
    (row) =>
      !row[0].startsWith("snap:") &&
      !row[0].startsWith("ghost-") &&
      atRest.has(row[0]) &&
      inkOf(samples[first]!, row[0]) > 0.5,
  );
  const distance = (row: Row) => Math.max(0, row[1] - center, center - (row[1] + row[2]));
  const anchor = kept.sort((a, b) => distance(a) - distance(b))[0];
  const anchorRest = anchor ? atRest.get(anchor[0]) : undefined;
  let anchorStep = 0;
  if (anchor)
    for (let index = first; index <= lastChange; index += 1) {
      const prior = samples[index - 1]!.rows.find((row) => row[0] === anchor[0]);
      const now = samples[index]!.rows.find((row) => row[0] === anchor[0]);
      if (prior && now && seen(prior[3]) && seen(now[3]))
        anchorStep = Math.max(anchorStep, Math.abs(now[1] - prior[1]));
    }
  // One kind of row's own numbers: its biggest inked step, its least ink once drawn, and when it is
  // first at full ink (ms from the fold's start).
  const rowNumbers = (match: (key: string) => boolean) => {
    const keys = new Set(samples.flatMap((sample) => sample.rows.map((row) => row[0])).filter(match));
    if (keys.size === 0) return undefined;
    let step = 0;
    let fullAt: number | undefined;
    let lowest = 1;
    let drawn = false;
    for (let index = first; index < samples.length; index += 1) {
      const rows = samples[index]!.rows.filter((row) => keys.has(row[0]));
      const prior = new Map(samples[index - 1]!.rows.map((row) => [row[0], row]));
      for (const row of rows) {
        const was = prior.get(row[0]);
        if (was && seen(was[3]) && seen(row[3])) step = Math.max(step, Math.abs(row[1] - was[1]));
        if (seen(row[3])) drawn = true;
        if (drawn && index <= lastChange) lowest = Math.min(lowest, row[3]);
      }
      if (fullAt === undefined && rows.length && rows.every((row) => row[3] >= 0.99))
        fullAt = samples[index]!.t - samples[first]!.t;
    }
    return {
      maxStepPx: round(step),
      fullInkMs: fullAt === undefined ? undefined : Math.round(fullAt),
      minInkOnceDrawn: round(lowest),
    };
  };
  // The recap card's live arrival (before the fold): from the frame it is first in the page, how long
  // until it is at full ink, its biggest step between frames, and the biggest step of any other inked
  // row then (the card's arrival moving its neighbours).
  const arrival = (() => {
    const at = samples.findIndex((sample) => sample.rows.some((row) => row[0].startsWith("nextStep")));
    if (at < 1) return undefined;
    let step = 0;
    let others = 0;
    let fullAt: number | undefined;
    for (let index = at; index < Math.min(samples.length, first); index += 1) {
      const prior = new Map(samples[index - 1]!.rows.map((row) => [row[0], row]));
      for (const row of samples[index]!.rows) {
        const was = prior.get(row[0]);
        if (!was || !seen(was[3]) || !seen(row[3])) continue;
        const moved = Math.abs(row[1] - was[1]) + Math.abs(row[2] - was[2]);
        if (row[0].startsWith("nextStep")) step = Math.max(step, moved);
        else others = Math.max(others, Math.abs(row[1] - was[1]));
      }
      const card = samples[index]!.rows.find((row) => row[0].startsWith("nextStep"));
      if (fullAt === undefined && card && card[3] >= 0.99) fullAt = samples[index]!.t - samples[at]!.t;
    }
    return {
      fullInkMs: fullAt === undefined ? undefined : Math.round(fullAt),
      cardStepPx: round(step),
      neighbourStepPx: round(others),
    };
  })();
  return {
    recapArrival: arrival,
    maxJumpPx: round(maxJump),
    maxJumpAnyInkPx: Math.round(maxJumpRaw * 10) / 10,
    worstFrameMs: Math.round(worstAt),
    durationMs: Math.round(samples[lastChange]!.t - samples[first]!.t),
    gashPx: Math.round(gash),
    frames: lastChange - first + 1,
    anchorDriftPx: anchor && anchorRest ? round(anchorRest[1] - anchor[1]) : undefined,
    anchorMaxStepPx: round(anchorStep),
    minMovedInk: Math.round(minInk * 100) / 100,
    recap: rowNumbers((key) => key.startsWith("nextStep")),
    subagent: rowNumbers((key) => key.startsWith("subagent")),
    foldStart: samples[first]!.t,
    foldEnd: samples[lastChange]!.t,
  };
}

if (import.meta.main) {
  const { createServer } = await import("vite");
  const { chromium } = await import("playwright");
  const PAGE = "/test/browser/fold-variants.html";
  const vite = await createServer({
    root: webviews,
    configFile: path.join(webviews, "vite.config.ts"),
    mode: "production",
    define: { "process.env.NODE_ENV": JSON.stringify("production") },
    cacheDir: path.join(webviews, "node_modules/.vite-fold-variants"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  const { warmViteServer } = await import("../test/support/warmDevServer");
  await warmViteServer(vite, PAGE);
  const { port } = vite.httpServer!.address() as { port: number };
  if (fixture) {
    const { copyFileSync } = await import("node:fs");
    mkdirSync(path.join(webviews, "node_modules/.fold-fixtures"), { recursive: true });
    copyFileSync(fixture, path.join(webviews, "node_modules/.fold-fixtures", path.basename(fixture)));
  }
  const name = (variant: string) => (tag ? `${tag}-${variant}` : variant);
  const browser = await chromium.launch({ headless: true });
  mkdirSync(out, { recursive: true });
  const results: Record<string, unknown> = {};
  for (const variant of variants) {
    const look = variant.name;
    const page: Page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 1 });
    page.on("pageerror", (error) => console.error(`${look}: ${error.message}`));
    page.on("console", (m) => m.type() === "warning" && console.error(m.text()));
    await page.goto(`http://127.0.0.1:${port}${PAGE}?width=${WIDTH}&height=${HEIGHT}`, { timeout: 180_000 });
    await page.waitForFunction(() => "__fold" in window, undefined, { timeout: 120_000 });
    const frames = path.join(out, `frames-${name(look)}`);
    rmSync(frames, { recursive: true, force: true });
    mkdirSync(frames, { recursive: true });
    const cdp = await page.context().newCDPSession(page);
    const shots: { file: string; t: number }[] = [];
    cdp.on("Page.screencastFrame", async (frame) => {
      const file = path.join(frames, `${String(shots.length).padStart(5, "0")}.jpg`);
      writeFileSync(file, Buffer.from(frame.data, "base64"));
      shots.push({ file, t: frame.metadata.timestamp! * 1000 });
      await cdp.send("Page.screencastFrameAck", { sessionId: frame.sessionId }).catch(() => {});
    });
    await cdp.send("Page.startScreencast", { format: "jpeg", quality: 90, everyNthFrame: 1 });
    const run = (await page.evaluate(
      ([look, scenario, end, recap, subagent]) =>
        (
          window as unknown as {
            __fold: {
              run(
                look: string,
                name: string,
                tailMs?: number,
                end?: number,
                options?: { recap?: string; subagent?: string },
              ): Promise<unknown>;
            };
          }
        ).__fold.run(look as string, scenario as string, undefined, end as number | undefined, {
          ...(recap && { recap }),
          ...(subagent && { subagent }),
        }),
      [variant.look, variant.scenario, end, variant.recap, variant.subagent] as const,
    )) as Run;
    await cdp.send("Page.stopScreencast");
    const numbers = measure(run);
    results[look] = numbers ?? { error: "no fold played" };
    console.log(`${look.padEnd(10)} ${JSON.stringify(numbers)}`);
    writeFileSync(path.join(out, `${name(look)}.samples.json`), JSON.stringify(run));
    if (numbers && shots.length) {
      // Page time to wall time: performance.timeOrigin + t.
      const from = run.startedAt + numbers.foldStart - 500;
      const to = run.startedAt + numbers.foldEnd + 600;
      const kept = shots.filter((shot) => shot.t >= from && shot.t <= to);
      const list = kept
        .map((shot, index) => {
          const next = kept[index + 1]?.t ?? shot.t + 1000 / 60;
          return `file '${shot.file}'\nduration ${Math.max(1, next - shot.t) / 1000}`;
        })
        .join("\n");
      const listFile = path.join(frames, "list.txt");
      writeFileSync(listFile, `${list}\nfile '${kept.at(-1)?.file}'\n`);
      const clip = path.join(out, `fold-${name(look)}.mp4`);
      const made = spawnSync(
        ffmpeg,
        [
          "-y",
          "-loglevel",
          "error",
          "-f",
          "concat",
          "-safe",
          "0",
          "-i",
          listFile,
          "-vf",
          "fps=60,format=yuv420p",
          "-c:v",
          "libx264",
          "-crf",
          "20",
          "-movflags",
          "+faststart",
          clip,
        ],
        { stdio: "inherit" },
      );
      if (made.status !== 0) console.error(`${look}: ffmpeg failed`);
    }
    await page.close();
  }
  writeFileSync(path.join(out, tag ? `results-${tag}.json` : "results.json"), JSON.stringify(results, null, 1));
  await browser.close();
  await vite.close();
}
