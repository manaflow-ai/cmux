// The transcript's running rows (compaction, tool groups, MCP calls, a message card, command and
// shell rows) draw `Spinner`: Leo 2026-10-20 ("why do these things not spin?") saw "Compacting the
// conversation…" with a ring that never moved, because no rule animated it. Agent work marks itself
// `data-working` so the working look (WORKING-LOOK, conversation.css) can draw it; the loops
// themselves are checked in a browser (test/static-status-loops.test.ts).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { CompactionNote } from "./CompactionNote";
import { Spinner, workingArcPath } from "./icons";

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

// The agent working-state mark is ChatGPT's ring with one gap, turning slowly (Leo 2026-11-02, on
// ChatGPT's beside ours: "THIS IS CHATGPT", "IT GOES SLOWER"): a bright arc of 0.72 of the ring
// (round caps, stroke 2 on the 16 viewBox) over a faint 22% track, one turn per 1400ms on the shared
// clock, as the native rows draw it. Not #31455's faint ring with a short 80° sweep, and never the
// macOS activity indicator's segmented spokes stepping round (#29903; Leo 2026-11-01: "why the f***
// did you make the spinner into this????").
test("agent work draws ChatGPT's gap ring: a 0.72 arc at stroke 2 over a faint track, turning once per 1.4 s", async () => {
  const working = renderToStaticMarkup(<Spinner />);
  const track = working.match(/<circle class="cv-spinner__track"[^>]*>/)?.[0] ?? "";
  expect(track).toContain('r="5.25"');
  expect(track).toContain('stroke-width="2"');
  const opacity = Number(track.match(/opacity="([\d.]+)"/)?.[1]);
  expect(opacity).toBeGreaterThanOrEqual(0.15);
  expect(opacity).toBeLessThanOrEqual(0.3);
  const arc = working.match(/<path class="cv-spinner__sweep"[^>]*>/)?.[0] ?? "";
  expect(arc).toContain('stroke-linecap="round"');
  expect(arc).toContain('stroke-width="2"');
  // 0.72 of the ring from 12 o'clock clockwise: one large-arc segment ending at about 259°.
  expect(arc).toContain('d="M8 2.75a5.25 5.25 0 1 1 2.84 8.98"');
  expect(working).not.toContain("cv-spinner__arc");
  expect(working).not.toContain("cv-spinner__spokes");
  expect(working).not.toContain("<line");
  // Loading (a check, a page) keeps its thin arc.
  const loading = renderToStaticMarkup(<Spinner loading />);
  expect(loading).toContain("cv-spinner__arc");
  expect(loading).toContain('stroke-width="1.5"');
  expect(loading).not.toContain("cv-spinner__sweep");
  const dir = import.meta.dir;
  for (const sheet of ["spinner.css", "conversation.css"]) {
    const css = await Bun.file(`${dir}/${sheet}`).text();
    expect(css).not.toMatch(/\.cv-spinner\[data-working\][^{]*\{[^}]*steps\(/);
    expect(css).not.toContain("cv-spinner__spokes");
  }
  // One turn per 1.4 s, on the page clock and as the fallback (ChatGPT's turns slower than our old 900ms).
  const desktop = await Bun.file(`${dir}/../../../pages/shared/desktop.css`).text();
  expect(desktop).toMatch(/--cmux-spinner-period: 1400ms;/);
  expect(await Bun.file(`${dir}/spinner.css`).text()).toContain("var(--cmux-spinner-period, 1400ms)");
});

// The working arc ends on its ring, at its share of the turn (#32730 drew the end as an offset from
// the start, so the arc left the track and bulged up and right of it).
test("the working arc runs along its ring and ends at its share of the turn", () => {
  for (const share of [0.25, 0.5, 0.72]) {
    const match = workingArcPath(share).match(/^M([\d.]+) ([\d.]+)([aA])([\d.]+) [\d.]+ 0 [01] 1 (-?[\d.]+) (-?[\d.]+)$/);
    expect(match).not.toBeNull();
    const [, sx, sy, command, radius, ex, ey] = match!;
    const end = command === "a" ? [Number(sx) + Number(ex), Number(sy) + Number(ey)] : [Number(ex), Number(ey)];
    expect(Math.hypot(end[0] - 8, end[1] - 8)).toBeCloseTo(Number(radius), 1);
    const turned = (Math.atan2(end[0] - 8, 8 - end[1]) / (2 * Math.PI) + 1) % 1;
    expect(turned).toBeCloseTo(share, 2);
  }
});
