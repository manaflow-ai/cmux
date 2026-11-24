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
import type { Browser, Page } from "playwright";

const webviews = path.resolve(import.meta.dir, "..");
const PAGE = "/test/browser/fold-variants.html";

const WIDTH = 720;
const HEIGHT = 640;

type Row = [key: string, top: number, height: number, ink: number, shownTop?: number, shownHeight?: number];
type Sample = { t: number; folding: boolean; view?: number; rows: Row[]; all?: Turned[] };
/** A mounted row, in view or not: key, top from the thread's top, height, kind (`opener`: it opens a turn). */
type Turned = [key: string, offset: number, height: number, kind: string];
type Run = {
  look: string;
  samples: Sample[];
  startedAt: number;
  view?: number;
  marks?: { step: number; t: number; label: string }[];
};

/** The run's numbers: over the frames from the fold's start to when nothing moves any more. */
export function measure(run: Run) {
  const { samples } = run;
  // No fold played (the `none` control, the swap applied at once): its numbers run from the turn's end.
  const ended = [...(run.marks ?? [])].reverse().find((mark) => mark.label.startsWith("turn_result"))?.t;
  const folded = samples.findIndex((sample) => sample.folding);
  const first = folded >= 0 ? folded : ended === undefined ? -1 : samples.findIndex((sample) => sample.t >= ended);
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
  // The reader's anchor: the row under the view's center on the frame before the fold, among the rows
  // still drawn at the end (a folded call is not an anchor; the nearest kept row is). Its drift is where it
  // ends against where it was; its step, the most it moves in one frame.
  const before = samples[Math.max(0, first - 1)]!;
  const last = samples.at(-1)!;
  const kept = new Set(last.rows.map((row) => row[0]));
  const center = (run.view ?? before.view ?? HEIGHT) / 2;
  const candidates = before.rows.filter(
    (row) => kept.has(row[0]) && !row[0].startsWith("ghost-") && !row[0].startsWith("snap:"),
  );
  const anchor = candidates
    .map((row) => ({
      row,
      off:
        row[1] <= center && center <= row[1] + row[2]
          ? 0
          : Math.min(Math.abs(row[1] - center), Math.abs(row[1] + row[2] - center)),
    }))
    .sort((a, b) => a.off - b.off)[0]?.row;
  let anchorStep = 0;
  let anchorDrift = 0;
  let anchorMax = 0;
  if (anchor) {
    let prior = anchor[1];
    for (let index = first; index <= lastChange; index += 1) {
      const row = samples[index]!.rows.find((r) => r[0] === anchor[0]);
      if (!row) continue;
      anchorStep = Math.max(anchorStep, Math.abs(row[1] - prior));
      anchorMax = Math.max(anchorMax, Math.abs(row[1] - anchor[1]));
      prior = row[1];
    }
    const end = last.rows.find((r) => r[0] === anchor[0]);
    if (end) anchorDrift = end[1] - anchor[1];
  }
  // The blink: the most a row that is drawn before and after the fold fades on the way (dissolve's cost).
  // A row and its snapshot (`snap:ID`, the replace looks) are two layers of paint: their ink together.
  const layered = (sample: Sample, key: string) => {
    const own = sample.rows.find((row) => row[0] === key)?.[3] ?? 0;
    const snap = sample.rows.find((row) => row[0] === `snap:${key}`)?.[3] ?? 0;
    return 1 - (1 - own) * (1 - snap);
  };
  let blink = 0;
  const steady = before.rows.filter(
    (row) => !row[0].startsWith("snap:") && row[3] > 0.95 && last.rows.some((r) => r[0] === row[0] && r[3] > 0.95),
  );
  for (const row of steady)
    for (let index = first; index <= lastChange; index += 1)
      blink = Math.max(blink, 1 - layered(samples[index]!, row[0]));
  const rest = band(samples.at(-1)!);
  let gash = 0;
  for (let index = first; index <= lastChange; index += 1) gash = Math.max(gash, band(samples[index]!) - rest);
  const round = (value: number) => Math.round(value * 10) / 10;
  // The rows that moved: drawn before the fold and at rest, at another top, and drawn on the fold's first
  // frame (a row the swap brought in under a kept id, the edits card, is new, not moved). Their ink on
  // each frame is the row's and its snapshot's (`snap:ID`) together, as two layers of paint.
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
      const prior = new Map((samples[index - 1]?.rows ?? []).map((row) => [row[0], row]));
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
    turnGrow: turnGrow(samples, run.marks ?? [], samples[lastChange]!.t),
    recapArrival: arrival,
    maxJumpPx: round(maxJump),
    maxJumpAnyInkPx: Math.round(maxJumpRaw * 10) / 10,
    worstFrameMs: Math.round(worstAt),
    durationMs: Math.round(samples[lastChange]!.t - samples[first]!.t),
    gashPx: Math.round(gash),
    anchorDriftPx: Math.round(anchorDrift * 10) / 10,
    anchorStepPx: Math.round(anchorStep * 10) / 10,
    anchorMaxPx: Math.round(anchorMax * 10) / 10,
    blink: Math.round(blink * 100) / 100,
    frames: lastChange - first + 1,
    minMovedInk: Math.round(minInk * 100) / 100,
    recap: rowNumbers((key) => key.startsWith("nextStep")),
    subagent: rowNumbers((key) => key.startsWith("subagent")),
    foldStart: samples[first]!.t,
    foldEnd: samples[lastChange]!.t,
  };
}

/**
 * The turn's tool rows growing at its end before they fold (Leo, 2026-11-22: "some sort of like... false grow
 * then collapse with the tool calls on the end of turn folding you have"). The block is what lies between the
 * last turn's opening prompt and its answer (or, with none, the row under the calls), as drawn; from the
 * turn's end (its `turn_end` record, after which no call comes) to the fold's last change it must never get
 * taller. `blockPx`: its most past its height at the turn's end; `answerPx`: the answer row's own growth over
 * the same frames (the reply's action room); `rows`: what was taller than at the turn's end at the peak.
 */
export function turnGrow(samples: Sample[], marks: { t: number; label: string }[], foldEnd: number) {
  const ended = [...marks].reverse().find((mark) => mark.label === "turn_end")?.t;
  const final = samples.at(-1)?.all;
  if (ended === undefined || !final) return undefined;
  // The turn's opening prompt: the first prompt past the last earlier turn's summary line (a steer is a prompt
  // inside the turn, so the block is the whole turn's).
  const ordered = [...final].sort((a, b) => a[1] - b[1]);
  const lastWhere = (rows: Turned[], test: (row: Turned) => boolean) => {
    for (let index = rows.length - 1; index >= 0; index -= 1) if (test(rows[index]!)) return index;
    return -1;
  };
  const lastPrompt = lastWhere(ordered, (row) => row[3] === "user" || row[3] === "opener");
  const summaryBefore = lastWhere(ordered.slice(0, lastPrompt), (row) => row[0].startsWith("summary-turn"));
  const opener = ordered.slice(summaryBefore + 1).find((row) => row[3] === "user" || row[3] === "opener");
  if (!opener) return undefined;
  const answer = final
    .filter((row) => row[3] === "assistant" && row[1] > opener[1])
    .sort((a, b) => b[1] - a[1])[0]?.[0];
  const block = (all: Turned[]) => {
    const open = all.find((row) => row[0] === opener[0]);
    if (!open) return undefined;
    const below = answer
      ? all.find((row) => row[0] === answer)
      : all.filter((row) => row[1] > open[1] && /^(thinking|summary-turn)/.test(row[0])).sort((a, b) => a[1] - b[1])[0];
    return below ? below[1] - (open[1] + open[2]) : undefined;
  };
  const start = samples.findIndex((sample) => sample.t >= ended);
  const base = start < 0 ? undefined : samples[start]!.all;
  const baseBlock = base && block(base);
  if (!base || baseBlock === undefined) return undefined;
  const heights = new Map(base.map((row) => [row[0], row[2]]));
  const answerBase = answer ? heights.get(answer) : undefined;
  let blockPx = 0;
  let answerPx = 0;
  let rows: string[] = [];
  for (const sample of samples.slice(start)) {
    if (sample.t > foldEnd || !sample.all) break;
    const now = block(sample.all);
    if (now !== undefined && now - baseBlock > blockPx) {
      blockPx = now - baseBlock;
      rows = sample.all
        .filter((row) => row[2] > (heights.get(row[0]) ?? 0) + 0.5)
        .map((row) => `${row[0]} +${Math.round(row[2] - (heights.get(row[0]) ?? 0))}`);
    }
    const reply = answer && sample.all.find((row) => row[0] === answer);
    if (reply && answerBase !== undefined) answerPx = Math.max(answerPx, reply[2] - answerBase);
  }
  return { blockPx: Math.round(blockPx * 10) / 10, answerPx: Math.round(answerPx * 10) / 10, rows };
}

/** A dev server for the recording page, warmed, and a headless Chrome: what every recording runs on. */
export async function openRecorder() {
  const { createServer } = await import("vite");
  const { chromium } = await import("playwright");
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
  const browser = await chromium.launch({ headless: true });
  return {
    browser,
    port,
    async close() {
      await browser.close();
      await vite.close();
    },
  };
}

export type RecordOptions = {
  look: string;
  /** The page's scenario name: `big-claude-turn`, `replay`, `url:PATH` or `matrix:JSON`. */
  scenario: string;
  /** Stop the chat at this step (a turn end) and fast-forward to shortly before it. */
  end?: number;
  width?: number;
  height?: number;
  out: string;
  /** Names the run's files: fold-NAME.mp4, NAME.samples.json. */
  name: string;
  ffmpeg: string;
  /** The recap entrance and subagent fold to play with (turnEndFold.ts), else the shipped ones. */
  recap?: string;
  subagent?: string;
};

/** Plays one look of one scenario in a fresh page, records its clip, and returns its numbers. */
export async function recordLook(browser: Browser, port: number, options: RecordOptions) {
  const { look, scenario, end, out, name, ffmpeg } = options;
  const width = options.width ?? WIDTH;
  const height = options.height ?? HEIGHT;
  const page: Page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
  page.on("pageerror", (error) => console.error(`${name}: ${error.message}`));
  await page.goto(`http://127.0.0.1:${port}${PAGE}?width=${width}&height=${height}`, { timeout: 180_000 });
  await page.waitForFunction(() => "__fold" in window, undefined, { timeout: 120_000 });
  const frames = path.join(out, `frames-${name}`);
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
    [look, scenario, end, options.recap, options.subagent] as const,
  )) as Run;
  await cdp.send("Page.stopScreencast");
  const numbers = measure(run);
  // Where the view sits in the page, for the clip's crop (the samples' tops are in the view's coordinates).
  const viewTop = await page.evaluate(() => document.querySelector(".acpmux-scroll")?.getBoundingClientRect().top ?? 0);
  writeFileSync(path.join(out, `${name}.samples.json`), JSON.stringify(run));
  let clip: string | undefined;
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
    // The event's bounds: every row that moves or changes ink between the fold's first frame and its
    // last, padded, so the clip shows the fold and not the page around it (full width: the rows are).
    const fromIndex = run.samples.findIndex((sample) => sample.t >= numbers.foldStart);
    let top = Infinity;
    let bottom = -Infinity;
    for (let index = Math.max(1, fromIndex); index < run.samples.length; index += 1) {
      if (run.samples[index]!.t > numbers.foldEnd) break;
      const prior = new Map(run.samples[index - 1]!.rows.map((row) => [row[0], row]));
      for (const row of run.samples[index]!.rows) {
        const was = prior.get(row[0]);
        if (was && Math.abs(was[1] - row[1]) < 0.25 && Math.abs(was[3] - row[3]) < 0.01) continue;
        top = Math.min(top, row[1], was?.[1] ?? Infinity);
        bottom = Math.max(bottom, row[1] + row[2], was ? was[1] + was[2] : -Infinity);
      }
    }
    const pad = 32;
    const cropTop = Number.isFinite(top) ? Math.max(0, Math.floor(viewTop + top - pad)) : 0;
    const cropBottom = Number.isFinite(bottom) ? Math.min(height, Math.ceil(viewTop + bottom + pad)) : height;
    const cropHeight = Math.max(2, Math.floor((cropBottom - cropTop) / 2) * 2);
    // The fold's first and last frames, marked: a bar along the top while it plays.
    const markFrom = ((kept[0] ? Math.max(0, run.startedAt + numbers.foldStart - kept[0].t) : 0) / 1000).toFixed(3);
    const markTo = (Number(markFrom) + numbers.durationMs / 1000).toFixed(3);
    const listFile = path.join(frames, "list.txt");
    writeFileSync(listFile, `${list}\nfile '${kept.at(-1)?.file}'\n`);
    clip = path.join(out, `fold-${name}.mp4`);
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
        `fps=60,crop=trunc(iw/2)*2:${cropHeight}:0:${cropTop},` +
          `drawbox=x=0:y=0:w=iw:h=4:color=orange@0.9:t=fill:enable='between(t,${markFrom},${markTo})',format=yuv420p`,
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
    if (made.status !== 0) {
      console.error(`${name}: ffmpeg failed`);
      clip = undefined;
    }
  }
  await page.close();
  return { numbers: numbers && clip ? { ...numbers, ...pixelChange(ffmpeg, clip) } : numbers, clip };
}

/**
 * What the clip's pixels say, apart from any row the page reports: each frame's mean luma change from the
 * one before (0 to 255, the marker bar cropped off), summed, and the share of that sum in the worst frame.
 * A swap applied at once puts nearly all its change in one frame (worstFrameShare near 1); a fold that
 * spreads it puts a small share in each. It sees what row positions cannot: content replaced in place.
 */
function pixelChange(ffmpeg: string, clip: string): { pixelChange?: number; worstFrameShare?: number } {
  const probe = spawnSync(
    ffmpeg,
    [
      "-loglevel",
      "error",
      "-i",
      clip,
      "-vf",
      "crop=iw:ih-6:0:6,tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-",
      "-f",
      "null",
      "-",
    ],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
  const values = [...(probe.stdout ?? "").matchAll(/lavfi\.signalstats\.YAVG=([\d.]+)/g)].map((m) => Number(m[1]));
  const total = values.reduce((sum, value) => sum + value, 0);
  if (!values.length || total <= 0) return {};
  return {
    pixelChange: Math.round(total * 10) / 10,
    worstFrameShare: Math.round((Math.max(...values) / total) * 100) / 100,
  };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const value = (name: string) => {
    const at = args.indexOf(name);
    return at >= 0 ? args[at + 1] : undefined;
  };
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
  if (fixture) {
    const { copyFileSync } = await import("node:fs");
    mkdirSync(path.join(webviews, "node_modules/.fold-fixtures"), { recursive: true });
    copyFileSync(fixture, path.join(webviews, "node_modules/.fold-fixtures", path.basename(fixture)));
  }
  mkdirSync(out, { recursive: true });
  const recorder = await openRecorder();
  const results: Record<string, unknown> = {};
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
  for (const variant of variants) {
    const look = variant.name;
    const { numbers } = await recordLook(recorder.browser, recorder.port, {
      look: variant.look,
      scenario: variant.scenario,
      ...(variant.recap && { recap: variant.recap }),
      ...(variant.subagent && { subagent: variant.subagent }),
      end,
      out,
      name: tag ? `${tag}-${look}` : look,
      ffmpeg,
    });
    results[look] = numbers ?? { error: "no fold played" };
    console.log(`${look.padEnd(10)} ${JSON.stringify(numbers)}`);
  }
  writeFileSync(path.join(out, tag ? `results-${tag}.json` : "results.json"), JSON.stringify(results, null, 1));
  await recorder.close();
}
