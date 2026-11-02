// The transcript's running rows (compaction, tool groups, MCP calls, a message card, command and
// shell rows) draw `Spinner`: Leo 2026-10-20 ("why do these things not spin?") saw "Compacting the
// conversation…" with a ring that never moved, because no rule animated it. Agent work marks itself
// `data-working` so the working look (WORKING-LOOK, conversation.css) can draw it; the loops
// themselves are checked in a browser (test/static-status-loops.test.ts).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { CompactionNote } from "./CompactionNote";
import { Spinner } from "./icons";

test("a running compaction draws the transcript spinner", () => {
  const html = renderToStaticMarkup(<CompactionNote compaction={{ state: "running" }} />);
  expect(html).toContain('class="cv-spinner"');
  expect(html).toContain("data-working");
});

test("a spinner keeps its own class next to the caller's", () => {
  const html = renderToStaticMarkup(<Spinner className="acpmux-harness-spinner" />);
  expect(html).toContain('class="cv-spinner acpmux-harness-spinner"');
});

test("a loading spinner (a harness check) never takes the working dot", () => {
  const html = renderToStaticMarkup(<Spinner loading />);
  expect(html).not.toContain("data-working");
  expect(html).not.toContain("cv-spinner__dot");
});

// Leo 2026-10-31: "what is this static symbol with a dot?" A working Spinner drew a still ring with
// a dot in its centre wherever conversation.css's spinner rules did not apply: the svg carries both
// the ring and the dot, and only a stylesheet hides the dot and turns the ring. The component now
// brings that default itself, so it holds on any page that draws it.
test("the spinner brings its own hidden dot and turning ring, not only conversation.css's", async () => {
  const dir = import.meta.dir;
  const source = await Bun.file(`${dir}/icons.tsx`).text();
  expect(source).toMatch(/^import "\.\/spinner\.css";$/m);
  const css = await Bun.file(`${dir}/spinner.css`).text();
  expect(css).toMatch(/\.cv-spinner__dot \{\s*display: none;/);
  expect(css).toMatch(/\.cv-spinner \{\s*animation: cmux-spin /);
  // Moved, not copied: one owner for each rule.
  const conversation = await Bun.file(`${dir}/conversation.css`).text();
  expect(conversation).not.toMatch(/^\.cv-spinner__dot \{/m);
  expect(conversation).not.toMatch(/\.cv-spinner \{\s*animation: cmux-spin /);
});

// The agent working-state mark is a faint full ring with a short bright sweep turning smoothly, as
// in Claude and ChatGPT and as the native rows draw it: never the 3/4 arc alone (Leo 2026-10-31: "who
// even decided to put that 3/4 circle") and never the macOS activity indicator's segmented spokes
// stepping round (#29903; Leo 2026-11-01: "why the f*** did you make the spinner into this????").
test("agent work draws a faint ring track with a short turning sweep, never the 3/4 arc or spokes", async () => {
  const working = renderToStaticMarkup(<Spinner />);
  const track = working.match(/<circle class="cv-spinner__track"[^>]*>/)?.[0] ?? "";
  expect(track).toContain('r="5.25"');
  const opacity = Number(track.match(/opacity="([\d.]+)"/)?.[1]);
  expect(opacity).toBeGreaterThanOrEqual(0.15);
  expect(opacity).toBeLessThanOrEqual(0.25);
  const sweep = working.match(/<path class="cv-spinner__sweep"[^>]*>/)?.[0] ?? "";
  expect(sweep).toContain('stroke-linecap="round"');
  // A short sweep: one small-arc segment (large-arc flag 0), not the 3/4 arc's large one.
  expect(sweep).toMatch(/d="M8 2\.75a5\.25 5\.25 0 0 1 [\d.]+ [\d.]+"/);
  expect(working).not.toContain("cv-spinner__arc");
  expect(working).not.toContain("cv-spinner__spokes");
  expect(working).not.toContain("<line");
  // Loading (a check, a page) keeps its thin arc.
  const loading = renderToStaticMarkup(<Spinner loading />);
  expect(loading).toContain("cv-spinner__arc");
  expect(loading).not.toContain("cv-spinner__sweep");
  const dir = import.meta.dir;
  for (const sheet of ["spinner.css", "conversation.css"]) {
    const css = await Bun.file(`${dir}/${sheet}`).text();
    expect(css).not.toMatch(/\.cv-spinner\[data-working\][^{]*\{[^}]*steps\(/);
    expect(css).not.toContain("cv-spinner__spokes");
  }
});
