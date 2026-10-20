#!/usr/bin/env bun
// Counts the real frames in runner.ts output folders. A frame is real when its stage reported ready,
// its PNG is on disk, and the picture is not one flat color. A run whose receipt has zero real frames
// rendered nothing a reviewer can look at, so gallery-advisory.yml fails it instead of going green.
//
//   bun frames.ts --dir head-run --dir base-run [--out frames.json] [--require]
//   -> {"total": 32, "real": 30, "unready": 1, "missing": 0, "blank": 1, "dirs": {...}}
//
// --require exits 1 when no folder holds a real frame.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { PNG } from "pngjs";

export type FrameCounts = { total: number; real: number; unready: number; missing: number; blank: number };

/** True when every pixel of the PNG has the same RGBA value (a blank or placeholder frame). */
export function isFlat(png: PNG): boolean {
  const { data } = png;
  if (data.length < 8) return true;
  const first = data.readUInt32BE(0);
  for (let i = 4; i < data.length; i += 4) if (data.readUInt32BE(i) !== first) return false;
  return true;
}

/** Counts one runner.ts output folder's frames by kind. A folder without results.json counts nothing. */
export function countFrames(dir: string): FrameCounts {
  const counts: FrameCounts = { total: 0, real: 0, unready: 0, missing: 0, blank: 0 };
  const file = join(dir, "results.json");
  if (!existsSync(file)) return counts;
  const results = JSON.parse(readFileSync(file, "utf8")) as { screenshot?: string; ready?: unknown }[];
  for (const result of results) {
    counts.total++;
    if (result.ready !== "1") {
      counts.unready++;
      continue;
    }
    const png = result.screenshot ? join(dir, result.screenshot) : "";
    if (!png || !existsSync(png)) {
      counts.missing++;
      continue;
    }
    let flat = true;
    try {
      flat = isFlat(PNG.sync.read(readFileSync(png)));
    } catch {
      flat = true; // An unreadable PNG is not a picture either.
    }
    if (flat) counts.blank++;
    else counts.real++;
  }
  return counts;
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: { dir: { type: "string", multiple: true }, out: { type: "string" }, require: { type: "boolean" } },
  });
  const dirs: Record<string, FrameCounts> = {};
  const sum: FrameCounts = { total: 0, real: 0, unready: 0, missing: 0, blank: 0 };
  for (const dir of values.dir ?? []) {
    const counts = countFrames(dir);
    dirs[dir] = counts;
    for (const key of Object.keys(sum) as (keyof FrameCounts)[]) sum[key] += counts[key];
  }
  const report = { ...sum, dirs };
  const text = JSON.stringify(report, null, 2);
  if (values.out) writeFileSync(values.out, text + "\n");
  console.log(text);
  if (values.require && sum.real === 0) {
    console.error(
      `gallery frames: zero real frames (${sum.total} rendered: ${sum.unready} not ready, ${sum.missing} missing, ${sum.blank} blank)`,
    );
    process.exit(1);
  }
}
