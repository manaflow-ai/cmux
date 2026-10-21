// The transcript's running rows (compaction, tool groups, MCP calls, a message card, command and
// shell rows) draw `Spinner`, and it turns: Leo 2026-10-20 ("why do these things not spin?") saw
// "Compacting the conversation…" with a ring that never moved, because no rule animated it. It runs
// the shared `cmux-spin` keyframes (ui/spinnerClock.ts keeps every page spinner on one phase),
// only with motion allowed and not under the static status look.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { CompactionNote } from "./CompactionNote";
import { Spinner } from "./icons";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "")
  .replace(/\s+/g, " ");

test("a running compaction draws the transcript spinner", () => {
  const html = renderToStaticMarkup(<CompactionNote compaction={{ state: "running" }} />);
  expect(html).toContain('class="cv-spinner"');
});

test("a spinner keeps its own class next to the caller's", () => {
  const html = renderToStaticMarkup(<Spinner className="acpmux-harness-spinner" />);
  expect(html).toContain('class="cv-spinner acpmux-harness-spinner"');
});

test("the transcript spinner turns on the shared clock, and holds still without motion", () => {
  const rule = css.match(
    /@media \(prefers-reduced-motion: no-preference\) \{ :root:not\(\[data-status-indicators="static"\]\) \.cv-spinner \{([^}]*)\}/,
  );
  expect(rule).not.toBeNull();
  expect(rule![1]).toContain("animation: cmux-spin var(--cmux-spinner-period, 900ms) linear infinite");
});
