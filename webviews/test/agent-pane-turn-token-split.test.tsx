// l10n-allow-file: test fixtures, not shipped UI.
// A turn's tokens split up (Leo, 2026-10-21: "usually anthropic talks about output instead of read
// tokens... its ok if we show both, we just ought to split it up"; and "shouldnt the token text and
// maybe time tho be less prominent? darker?"). The running line and a finished turn's Worked for
// say output first, then all the model read (fresh input, cache reads and writes), each in its own
// span, with the parts named on hover; the time sits in the quieter time span, not in the words.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { WorkedFor } from "../src/agent-session/acpmux/conversation/TurnRows";
import { tokenDetail } from "../src/agent-session/acpmux/conversation/TurnTokens";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { SPLIT, tokenLineMarkup, tokenLines } from "./support/turnTokenLines";

const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const SPLIT_SPAN =
  /<span class="cv-worked__tokens is-split" title="Output 12\.4K · fresh input 18K · cache reads 2\.1M · cache writes 42K"><span class="cv-worked__tokens-part">↓ 12\.4K out<\/span><span class="cv-worked__tokens-part">↑ 2\.1M in<\/span><\/span>/;

for (const [name, line] of Object.entries(tokenLines))
  test(`${name}: output first, then what the model read, named on hover`, () => {
    const html = tokenLineMarkup(line, SPLIT);
    expect(html).toMatch(SPLIT_SPAN);
    expect(text(html)).toMatch(/· ↓ 12\.4K out ↑ 2\.1M in$/);
    // The time is in its own quieter span.
    expect(html).toMatch(/<span class="cv-worked__(label-)?time">35s<\/span>/);
  });

test("the hover names each part, compact in the pane's language", () => {
  expect(tokenDetail(translatorFor("en"), "en", SPLIT)).toBe(
    "Output 12.4K · fresh input 18K · cache reads 2.1M · cache writes 42K",
  );
});

const worked: AcpmuxRow = {
  id: "worked-u1",
  kind: "worked",
  version: 1,
  at: 0,
  status: "completed",
  durationMs: 76_000,
  toolCount: 2,
};
const workedMarkup = (row: AcpmuxRow) =>
  renderToStaticMarkup(<WorkedFor row={row} expanded={false} onToggle={() => {}} />);

test("a finished turn's Worked for says its tokens split, its time in the quieter span", () => {
  const html = workedMarkup({ ...worked, tokens: SPLIT });
  expect(text(html)).toBe("Worked for 1m 16s · ↓ 12.4K out ↑ 2.1M in");
  expect(html).toContain(
    '<span class="cv-worked__label">Worked for <span class="cv-worked__label-time">1m 16s</span></span>',
  );
  expect(html).toMatch(SPLIT_SPAN);
  // A turn whose result named no tokens: the time alone.
  expect(text(workedMarkup(worked))).toBe("Worked for 1m 16s");
  // An empty turn_result's all-zero split: no tokens, and no dangling separator.
  const zero = { output: 0, input: 0, cacheRead: 0, cacheWrite: 0 };
  expect(text(workedMarkup({ ...worked, tokens: zero }))).toBe("Worked for 1m 16s");
  expect(workedMarkup({ ...worked, tokens: zero })).not.toContain("cv-worked__sep");
  // A stopped turn keeps its own words.
  expect(text(workedMarkup({ ...worked, status: "cancelled" }))).toBe("You stopped after 1m 16s");
});

test("the time and both token parts take the tertiary text token, in tabular numerals", () => {
  const css = readFileSync(
    path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
    "utf8",
  );
  const at = css.indexOf("\n.cv-worked__time,\n.cv-worked__label-time {");
  expect(at).toBeGreaterThan(-1);
  const rule = css.slice(at, css.indexOf("}", at));
  expect(rule).toContain("color: var(--cv-text-dim);");
  expect(rule).toContain("font-variant-numeric: tabular-nums;");
});

// A finished connected turn has one Worked-for line, including its intermediate replies and
// steers. That line spans the whole turn, so it carries the turn's token count.
let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const ran = (id: string) =>
  row(id, "activity", {
    items: [{ kind: "tool", text: "", tool: { id, title: id, kind: "execute", status: "completed" } }],
  });
const takeaway = (id: string) =>
  row(id, "assistant", {
    text: `${id}: the import moves your shell history, bookmarks and themes into the app.\n\nTwo things for you:\n1. Pick the profile to import.\n2. Say whether to keep the old one.`,
  });
const ended = () => row("end", "turnSummary", { status: "completed", durationMs: 9_000, tokens: SPLIT });
const workedTokens = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set(), { working: false })
    .filter((shaped) => shaped.kind === "worked")
    .map((shaped) => [shaped.id, shaped.tokens]);

test("a turn with one Worked for carries the turn's tokens on it", () => {
  expect(workedTokens([row("u", "user"), ran("ran-1"), ran("ran-2"), takeaway("done"), ended()])).toEqual([
    ["worked-u", SPLIT],
  ]);
});

test("a turn with intermediate replies keeps its tokens on its single fold", () => {
  expect(
    workedTokens([row("u", "user"), ran("ran-1"), takeaway("first"), ran("ran-2"), takeaway("second"), ended()]),
  ).toEqual([["worked-u", SPLIT]]);
});

test("a steered turn keeps its tokens on the original prompt's fold", () => {
  expect(
    workedTokens([
      row("u", "user"),
      ran("ran-1"),
      row("s", "user", { text: "also the retry path", steer: "landed" }),
      ran("ran-2"),
      takeaway("done"),
      ended(),
    ]),
  ).toEqual([["worked-u", SPLIT]]);
});
