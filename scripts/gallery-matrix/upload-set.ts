#!/usr/bin/env bun
// What a gallery health run (health.ts --output-dir) uploads. Its readers need little: merge_hold
// (scripts/ci/base_red_excuse.py) and the replay's classifier (scripts/ci/test_reds.py) read health.json;
// shift-baseline.ts, ready-budgets.ts and invariant-baseline.ts read each attempt's results.json; a
// person debugging a red state wants that state's screenshots and its base replay's. Nothing reads a
// passing state's screenshot, and a full render wrote one for each of ~2,300 cases a shard, ~190 MB a
// shard and ~1.45 GB a run (cmuxterm-hq#9131). So before the upload this deletes every screenshot that
// is not a red state's:
//
// - A red state is one health.json lists as broken (`fresh`, `known`), slow, shifted or past its
//   geometry baseline. Its screenshots stay in every attempt, the base replay's included (the replay
//   renders only red states).
// - A shard with no verdict (no health.json, or one that says the render failed) keeps every
//   screenshot: no state of it passed.
// - `--keep` names states (`entry#variant`) or entries (`entry`) to keep as well, or `all` to keep
//   every screenshot (the full-gallery browse in each attempt's index.html). The workflow's dispatch
//   input `screenshots` passes it; it is empty by default.
//
// Every other file (health.json, source.json, results.json, index.html, geometry JSON) stays. The run
// prints the bytes before and after, and warns when what stays besides red states' screenshots is past
// FIXED_BYTES_LIMIT: the ratchet that keeps a run with no red state small.
//
//   bun upload-set.ts --dir "$RUNNER_TEMP/health" [--keep all|STATE,ENTRY,...] [--dry-run]
import { appendFileSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { stateKey } from "./health";

/** A screenshot or recording: what the upload keeps only for a red or requested state. */
export const MEDIA = /\.(png|jpe?g|webp|webm|mp4)$/i;
/** Bytes a shard may upload besides red states' screenshots (JSON, index.html). Lower it, never raise it. */
export const FIXED_BYTES_LIMIT = 8 * 1024 * 1024;

type Listed = { state?: unknown };

/** The red states of a health.json, or null when it gives no verdict (missing, not JSON, or an error). */
export function redStates(text: string | null): Set<string> | null {
  if (text === null) return null;
  let found: Record<string, unknown>;
  try {
    found = JSON.parse(text) as Record<string, unknown>;
  } catch {
    return null;
  }
  if (!found || typeof found !== "object" || found.error || !Array.isArray(found.fresh)) return null;
  const red = new Set<string>();
  for (const key of ["fresh", "known", "slow", "shifted", "geometry"])
    for (const item of (found[key] as Listed[] | undefined) ?? []) if (typeof item?.state === "string") red.add(item.state);
  return red;
}

/** Every media file name a result names (its screenshot, play stills, workflow evidence, diff image). */
export function mediaOf(result: unknown, into = new Set<string>()): Set<string> {
  if (typeof result === "string") {
    if (MEDIA.test(result)) into.add(basename(result));
  } else if (Array.isArray(result)) {
    for (const item of result) mediaOf(item, into);
  } else if (result && typeof result === "object") {
    for (const value of Object.values(result)) mediaOf(value, into);
  }
  return into;
}

export type Plan = { keep: string[]; drop: string[]; red: string[]; verdict: boolean };

/** Which files under `dir` (paths relative to it) the upload keeps and which it drops. */
export function plan(dir: string, requested: string[] = []): Plan {
  const files = (readdirSync(dir, { recursive: true, encoding: "utf8" }) as string[])
    .filter((path) => statSync(join(dir, path)).isFile())
    .sort();
  const read = (path: string) => {
    try {
      return readFileSync(join(dir, path), "utf8");
    } catch {
      return null;
    }
  };
  const red = redStates(read("health.json"));
  const all = red === null || requested.includes("all");
  const wanted = (state: string) =>
    red!.has(state) || requested.includes(state) || requested.includes(state.slice(0, state.lastIndexOf("#")));
  // A media file stays when a result of its own folder that names it is a wanted state's.
  const kept = new Set<string>();
  if (!all)
    for (const path of files.filter((file) => basename(file) === "results.json")) {
      let results: unknown;
      try {
        results = JSON.parse(read(path) ?? "[]");
      } catch {
        continue;
      }
      if (!Array.isArray(results)) continue;
      const folder = dirname(path);
      for (const result of results as { params?: Record<string, unknown> }[])
        if (wanted(stateKey(result))) for (const name of mediaOf(result)) kept.add(folder === "." ? name : join(folder, name));
    }
  const keep: string[] = [];
  const drop: string[] = [];
  for (const file of files) (all || !MEDIA.test(file) || kept.has(file) ? keep : drop).push(file);
  return { keep, drop, red: [...(red ?? [])].sort(), verdict: red !== null };
}

const bytes = (dir: string, paths: string[]) => paths.reduce((sum, path) => sum + statSync(join(dir, path)).size, 0);
const mb = (n: number) => `${(n / 1024 / 1024).toFixed(1)} MB`;

/** Bytes of the kept files that are not media: what a run with no red state uploads. */
export const fixedBytes = (dir: string, keep: string[]) => bytes(dir, keep.filter((path) => !MEDIA.test(path)));

function main(): void {
  const { values } = parseArgs({
    options: { dir: { type: "string" }, keep: { type: "string", default: "" }, "dry-run": { type: "boolean", default: false } },
  });
  if (!values.dir) throw new Error("--dir <a gallery health output dir> is required");
  const requested = values.keep.split(",").map((item) => item.trim()).filter(Boolean);
  const { keep, drop, red, verdict } = plan(values.dir, requested);
  const before = bytes(values.dir, [...keep, ...drop]);
  const after = bytes(values.dir, keep);
  const fixed = fixedBytes(values.dir, keep);
  if (!values["dry-run"]) for (const path of drop) rmSync(join(values.dir, path));
  const media = keep.filter((path) => MEDIA.test(path)).length;
  const lines = [
    `Gallery health upload: ${mb(after)} of ${mb(before)} (${after} of ${before} bytes); ${media} screenshot(s) kept, ${drop.length} dropped.`,
    verdict
      ? `Screenshots kept for ${red.length} red state(s)${requested.length ? ` and the requested ${requested.join(", ")}` : ""}.`
      : "No verdict (health.json missing or an error): every screenshot is kept.",
  ];
  if (fixed > FIXED_BYTES_LIMIT)
    lines.push(
      `::warning::gallery health uploads ${mb(fixed)} besides red states' screenshots, past upload-set.ts FIXED_BYTES_LIMIT (${mb(FIXED_BYTES_LIMIT)}): find what grew`,
    );
  console.log(lines.join("\n"));
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${lines.filter((line) => !line.startsWith("::")).join("\n")}\n`);
}

if (import.meta.main) main();
