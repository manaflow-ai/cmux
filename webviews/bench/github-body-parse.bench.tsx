// l10n-allow-file: benchmark fixtures and output, not shipped UI.
// The GitHub page's bodies drawn again on a revisit: a pull request's body and its comments (or an
// issue list's rows), each GitHubMarkdown mounted once per visit, as leaving for another pull request
// and coming back does. Each round draws BODIES bodies VISITS times with react-dom/server and reads
// the total in ms; the run prints p50 and spread of ROUNDS rounds. The same harness runs on the base
// and on the change: it renders the component, so it reads whatever GitHubMarkdown does per mount.
// Duress: the same at 4x and 10x the bodies, the 10x past the cache's entry bound (every visit
// evicts what the next one needs), which reads the miss path's cost over the base.
//   bun bench/github-body-parse.bench.tsx [rounds=5]
/// <reference types="bun" />
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { GitHubMarkdown } from "../src/pages/github/GitHubMarkdown";

const ROUNDS = Number(process.argv[2] ?? 5);
const VISITS = 10;
const open = () => {};

function body(seed: number): string {
  const lines = [
    `## Change ${seed}`,
    "",
    `This fixes **issue ${seed}** in \`src/thing${seed}.ts\`; see [the run](https://github.com/o/r/actions/runs/${seed}).`,
    "",
  ];
  for (let i = 0; i < 6; i += 1)
    lines.push(`- [${i % 2 ? "x" : " "}] step ${i} of ${seed} with _emphasis_ and ~~old~~ text`);
  lines.push(
    "",
    "```ts",
    ...Array.from({ length: 12 }, (_, i) => `const value${i} = compute(${seed}, ${i}); // line ${i}`),
    "```",
    "",
  );
  lines.push(
    "| case | before | after |",
    "|---|---|---|",
    ...Array.from({ length: 5 }, (_, i) => `| c${i} | ${seed + i} ms | ${i} ms |`),
    "",
  );
  lines.push("> A quoted review note that runs on for a while to look like a real comment body. ".repeat(3));
  return lines.join("\n");
}

let fresh = 0;

// Each round's bodies are new text, so a round reads a first visit (every body parsed) and nine
// revisits, not a cache already full.
function round(count: number): number {
  const bodies = Array.from({ length: count }, () => body((fresh += 1)));
  const start = performance.now();
  for (let visit = 0; visit < VISITS; visit += 1) {
    for (const source of bodies) renderToStaticMarkup(createElement(GitHubMarkdown, { source, open }));
  }
  return performance.now() - start;
}

function report(label: string, count: number) {
  round(count); // warm the JIT
  const runs = Array.from({ length: ROUNDS }, () => round(count)).sort((a, b) => a - b);
  const p50 = runs[Math.floor(runs.length / 2)]!;
  console.log(
    `${label} bodies=${count} visits=${VISITS} p50=${p50.toFixed(1)}ms min=${runs[0]!.toFixed(1)} max=${runs.at(-1)!.toFixed(1)}`,
  );
}

report("1x", 60);
report("4x", 240);
report("10x", 600);
