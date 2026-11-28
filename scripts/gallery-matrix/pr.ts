#!/usr/bin/env bun
// The per-PR gallery diff from three matrix runs (runner.ts output folders): the merge-base, the
// head and the head again. Writes the diff folder: index.html, outcomes.json, summary.json (the
// feed card), comment.md (the sticky PR comment) and the images they show.
//
//   bun pr.ts --base base-run --head head-run --repeat head-run-2 \
//     --base-manifest base.json --head-manifest head.json --out diff \
//     --pr 18189 --head-sha <sha> --base-sha <sha> [--diff-url U] [--gallery-url U] [--matrix-url U] [--feed-url U]
//     [--artifact-url U] [--thumb-base U] [--branch B (the live preview /wt/<name>/ in the comment)]
//
// With --outcomes (an earlier run's outcomes.json) it only writes the reports, so a publisher can
// rebuild the comment from data without running the comparison or the PR's code.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { compareRuns, type Outcome } from "./compare";
import { commentMarkdown, commentThumbs, diffPage, feedSummary, liveBase, type ReportMeta } from "./report";

const caseIds = (file: string | undefined) =>
  new Set(
    file && existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as { id: string }[]).map((c) => c.id) : [],
  );

if (import.meta.main) {
  const { values } = parseArgs({
    options: {
      base: { type: "string" },
      head: { type: "string" },
      repeat: { type: "string" },
      "base-manifest": { type: "string" },
      "head-manifest": { type: "string" },
      out: { type: "string" },
      outcomes: { type: "string" },
      pr: { type: "string" },
      "head-sha": { type: "string", default: "" },
      "base-sha": { type: "string", default: "" },
      "diff-url": { type: "string" },
      "gallery-url": { type: "string" },
      "matrix-url": { type: "string" },
      "feed-url": { type: "string" },
      "thumb-base": { type: "string" },
      "artifact-url": { type: "string" },
      branch: { type: "string" },
    },
  });
  const required = values.outcomes
    ? (["out", "pr"] as const)
    : (["base", "head", "head-manifest", "out", "pr"] as const);
  for (const name of required) if (!values[name]) throw new Error(`--${name} is required`);
  const out = values.out!;
  mkdirSync(out, { recursive: true });
  const outcomes: Outcome[] = values.outcomes
    ? JSON.parse(readFileSync(values.outcomes, "utf8"))
    : compareRuns({
        baseDir: values.base!,
        headDir: values.head!,
        repeatDir: values.repeat,
        baseIds: caseIds(values["base-manifest"]),
        headIds: caseIds(values["head-manifest"]),
        outDir: out,
      });
  const meta: ReportMeta = {
    pr: Number(values.pr),
    head: values["head-sha"]!,
    base: values["base-sha"]!,
    links: {
      diff: values["diff-url"],
      gallery: values["gallery-url"],
      matrix: values["matrix-url"],
      feed: values["feed-url"],
      thumbBase: values["thumb-base"],
      artifact: values["artifact-url"],
      live: values.branch ? liveBase(values.branch) : undefined,
    },
  };
  writeFileSync(join(out, "outcomes.json"), `${JSON.stringify(outcomes, null, 2)}\n`);
  writeFileSync(join(out, "summary.json"), `${JSON.stringify(feedSummary(outcomes, meta), null, 2)}\n`);
  writeFileSync(join(out, "comment.md"), commentMarkdown(outcomes, meta));
  // thumbs.txt: the keys whose thumbnails the comment shows, for the publisher to upload.
  writeFileSync(
    join(out, "thumbs.txt"),
    commentThumbs(outcomes, meta)
      .map((o) => `${o.key}\n`)
      .join(""),
  );
  if (!values.outcomes) writeFileSync(join(out, "index.html"), diffPage(outcomes, meta));
  console.log(feedSummary(outcomes, meta).summary);
}
