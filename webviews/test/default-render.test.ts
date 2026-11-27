// What a person with no settings sees in the agent pane, as text: every experiment's default arm (the look or
// behaviour that ships) and the default look the golden screen draws (looks.json's first entry). The native
// half is Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/DefaultRenderBaselineTests.swift.
//
// Leo, 2026-11-24 00:50Z, after cmux#52340: "in general we just wanna make sure in future e.g. we dont accidentally
// unintnteially merge a weird customization as a default thingy". A new arm or look is opt-in; a change to this
// baseline is a change to everyone's app, so land-judge's removal-merged-unnoticed rule (leo-workspace
// tools/silent_removal.py, "default render") refuses the PR unless its body has `changes default: Leo, YYYY-MM-DD:
// "..."`. Class page: cmuxterm-hq docs/handbook/customization-leaked-into-default.md.
//
// A PR that means to change a default regenerates it: CMUX_UPDATE_DEFAULT_RENDER=1 bun test test/default-render.test.ts
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { EXPERIMENTS } from "../src/experiments/registry";
import looks from "../src/gallery/golden/looks.json";

const BASELINE = path.join(import.meta.dir, "fixtures/default-render/webviews.txt");

function render(): string {
  const arms = [...EXPERIMENTS]
    .sort((a, b) => a.id.localeCompare(b.id))
    .map((e) => `experiment ${e.id} = ${e.defaultArm}`);
  const first = looks.looks[0] as { id: string; schemes: unknown; settings?: unknown; composerLook?: unknown };
  const look = [
    `look ${first.id}`,
    `look.settings = ${JSON.stringify(first.settings ?? {})}`,
    `look.composerLook = ${JSON.stringify(first.composerLook ?? null)}`,
    `look.schemes = ${JSON.stringify(first.schemes)}`,
  ];
  return [
    "# What a person with no settings sees in the agent pane (test/default-render.test.ts). Changing a line changes",
    '# everyone\'s app: the PR quotes Leo in a `changes default: Leo, YYYY-MM-DD: "..."` line (land-judge refuses it',
    "# otherwise). Regenerate: CMUX_UPDATE_DEFAULT_RENDER=1.",
    "",
    "## default look (golden screen, first row)",
    ...look,
    "",
    "## experiments: the arm that ships",
    ...arms,
    "",
  ].join("\n");
}

test("the default look and every experiment's shipped arm match the baseline", () => {
  const drawn = render();
  if (process.env.CMUX_UPDATE_DEFAULT_RENDER === "1") {
    mkdirSync(path.dirname(BASELINE), { recursive: true });
    writeFileSync(BASELINE, drawn);
    return;
  }
  const kept = existsSync(BASELINE) ? readFileSync(BASELINE, "utf8") : "";
  if (kept !== drawn) console.log(`default-render-begin\n${drawn}default-render-end`);
  expect(looks.looks[0]?.id).toBe("cmux");
  expect(drawn).toBe(kept);
});
