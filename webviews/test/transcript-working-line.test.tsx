// l10n-allow-file: test fixture tool titles, not shipped UI.
// The running turn's status line, as Claude desktop draws it (#21604 row 2,
// transcript-task-list-in-progress.png): what the agent is doing now. While a tool call runs the
// line names it and keeps the turn's time beside it; between calls it reads "Working for 42s" as
// before, and before any work "Thinking". No mark blinks before any of them (Leo, 2026-10-20: the
// three pulsing dots were "the blinking ascii"; the ticking time says the turn is alive).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ActivityLine } from "../src/agent-session/acpmux/conversation/ActivityLine";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { WorkingFor } from "../src/agent-session/acpmux/conversation/WorkingFor";
import { turnView, WORKING } from "../src/agent-session/acpmux/conversation/turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const call = (id: string, status: string) => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind: "execute", status },
});

function statusLine(calls: ReturnType<typeof call>[]): AcpmuxRow {
  const live = [row("u", "user"), row("a", "assistant", { text: "On it." }), row("run", "activity", { items: calls })];
  const status = turnView(live, new Set(), { working: true }).find((entry) => entry.kind === WORKING);
  if (!status) throw new Error("no status line");
  return status;
}

const drawn = (status: AcpmuxRow) => renderToStaticMarkup(<WorkingFor row={status} now={() => status.at + 26_000} />);
// The line draws nothing before its words: no working mark, no activity dots, and its first child
// is the label itself.
const stillMarkup = (html: string) =>
  /^<div[^>]*><(?:span|output) class="cv-(?:worked__label|thinking|activity__label)/.test(html) &&
  !/cv-working-mark|cv-activity__dots/.test(html);
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("while a call runs, the status line names it beside the turn's time", () => {
  const status = statusLine([call("git log", "completed"), call("bun test", "in_progress")]);
  expect(status.doing).toBe("bun test");
  const html = drawn(status);
  expect(text(html)).toBe("bun test 26s");
  expect(stillMarkup(html)).toBe(true);
});

test("between calls, the line reads Working for, with no mark before it", () => {
  const status = statusLine([call("git log", "completed")]);
  expect(status.doing).toBeUndefined();
  const html = drawn(status);
  expect(text(html)).toBe("Working for 26s");
  expect(stillMarkup(html)).toBe(true);
});

test("Thinking is the word alone, with no mark before it; the word itself shimmers", () => {
  const html = renderToStaticMarkup(<Thinking />);
  expect(text(html)).toBe("Thinking");
  expect(stillMarkup(html)).toBe(true);
  expect(html).toContain('class="cv-thinking is-shimmer"');
});

test("the start status before the turn does not shimmer", () => {
  const html = renderToStaticMarkup(<Thinking status="Starting Claude Code…" />);
  expect(html).not.toContain("is-shimmer");
});

test("the activity line names the work with no dots before it", () => {
  const html = renderToStaticMarkup(
    <ActivityLine row={row("act", "activity-line", { text: "Edit grid.css" })} now={() => at + 26_000} />,
  );
  expect(text(html)).toMatch(/^Edit grid\.css \d+s$/);
  expect(stillMarkup(html)).toBe(true);
});

test("a call whose title is its raw input reads as a label, not JSON", () => {
  const read = {
    kind: "tool",
    text: "",
    tool: {
      id: "r",
      title: '{"file_path":"src/app.ts"}',
      kind: "read",
      status: "in_progress",
      inputSummary: '{"file_path":"src/app.ts"}',
    },
  };
  const status = statusLine([read]);
  expect(status.doing).toContain("app.ts");
  expect(status.doing).not.toContain("{");
});

test("no dots loop on the running line; only the word Thinking shimmers, in the theme accent", async () => {
  const css = await Bun.file(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  ).text();
  expect(css).not.toContain("cv-thinking-sweep");
  expect(css).not.toMatch(/cv-working-mark|cv-working-dot|cv-activity__dots|cv-activity-dot/);
  // The sweep runs only with motion allowed and the status look not static, on the shared clock's
  // keyframes, its band mixed from the theme accent (never a literal color).
  const rule = css.match(
    /@media \(prefers-reduced-motion: no-preference\) \{\s*:root:not\(\[data-status-indicators="static"\]\) \.cv-thinking\.is-shimmer \{([^}]*)\}/,
  );
  expect(rule).not.toBeNull();
  expect(rule![1]).toContain("animation: cmux-shimmer");
  expect(rule![1]).toContain("var(--agent-accent");
  expect(rule![1]).not.toMatch(/#[0-9a-f]{3,8}\b|rgb\(|orange/i);
});

// Find counts and visits only transcript rows (findMatches skips the working row), so the status
// line must not be painted either, or searching the running command highlights a match the count
// never reaches (chatFind.ts paintFindHighlights skips [data-find-skip]).
test("Find skips the status line: it is not a match the count can reach", () => {
  const skipped = (html: string) => /^<div class="cv-worked[^"]*" data-find-skip="/.test(html);
  expect(skipped(drawn(statusLine([call("bun test", "in_progress")])))).toBe(true);
  expect(skipped(drawn(statusLine([call("git log", "completed")])))).toBe(true);
  expect(skipped(renderToStaticMarkup(<Thinking />))).toBe(true);
});
