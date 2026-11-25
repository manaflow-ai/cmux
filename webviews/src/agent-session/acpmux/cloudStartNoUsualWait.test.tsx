// l10n-allow-file: test fixture words, not shipped UI.
// A Cloud start never says how long a step "usually" takes: every step counts its own seconds
// (Austin, 2026-11-24: "show the seconds, dont need to show usually under a minute that stuff";
// https://github.com/manaflow-ai/cmux/issues/55519). Two guards: every step in every look draws a
// live clock and no "usually", and no shipped web UI source or catalog carries the old ETA words or
// their `cloudStart.eta.*` keys, so they cannot come back through a merge or an old string table.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { CloudStartView } from "./CloudStartView";
import { CLOUD_START_STEPS, type CloudStartProgress } from "./cloudStartProgress";

const base: CloudStartProgress = {
  key: "k",
  task: "fix the build",
  state: "starting",
  folder: "paint",
  machine: "paint-dev",
};

test("every Cloud start step counts live seconds and never says how long it usually takes", () => {
  const now = Date.now();
  for (const step of CLOUD_START_STEPS)
    for (const quietLook of ["inline", "stacked", "hint"] as const) {
      const html = renderToStaticMarkup(<CloudStartView start={{ ...base, step }} quietLook={quietLook} />);
      expect(html, `${step} ${quietLook}`).toMatch(/data-stage-clock="true">\d+s</);
      expect(html.toLowerCase(), `${step} ${quietLook}`).not.toContain("usually");
    }
  // The copy, 12 s in: "Copying your project · 12s", as the issue asks.
  const copying = renderToStaticMarkup(
    <CloudStartView
      start={{ ...base, step: "folder", machineStartedAt: now - 40_000, machineFinishedAt: now - 12_400 }}
    />,
  );
  expect(copying).toContain("Copying your project");
  expect(copying).toMatch(/data-stage-clock="true">12s</);
  expect(copying).not.toContain("usually");
});

const WEB_SRC = join(import.meta.dir, "..", "..");
const SHIPPED = /\.(tsx?|xcstrings|json)$/;
const NOT_SHIPPED = /\.(test|gallery|stories)\.tsx?$/;
// The words the quiet line used to show, and their catalog keys.
const ETA = /usually (under a minute|a few seconds|about \d)|cloudStart\.eta\./i;

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (name === "node_modules") return [];
    return statSync(path).isDirectory() ? files(path) : [path];
  });
}

test("no shipped agent-pane or Cloud progress source says how long a step usually takes", () => {
  const roots = [join(WEB_SRC, "agent-session"), join(WEB_SRC, "pages", "cloud-progress")];
  const offenders = roots
    .flatMap(files)
    .filter((path) => SHIPPED.test(path) && !NOT_SHIPPED.test(path))
    .flatMap((path) =>
      readFileSync(path, "utf8")
        .split("\n")
        .map((line, index) => ({ path, line: index + 1, text: line }))
        // Comments quoting the request are fine; shipped strings and keys are not.
        .filter(({ text }) => ETA.test(text) && !/^\s*(\/\/|\*|\/\*)/.test(text)),
    )
    .map(({ path, line, text }) => `${path.slice(WEB_SRC.length + 1)}:${line}: ${text.trim().slice(0, 120)}`);
  expect(offenders).toEqual([]);
});
