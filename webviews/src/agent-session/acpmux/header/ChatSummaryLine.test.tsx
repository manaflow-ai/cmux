// l10n-allow-file: test fixture summaries, not shipped UI.
// The chat header's rolling summary (ChatSummaryLine.tsx): the daemon's `rollingSummary` beside the
// chat's name, its next action after an arrow, the whole text as its tooltip; nothing before the
// first summary.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { rollingSummaryOf } from "../direct";
import { translate } from "../i18n";
import { ChatSummaryLine } from "./ChatSummaryLine";

const html = (node: React.ReactElement) => renderToStaticMarkup(node);

test("a summary with a next action reads as one phrase, so the header cuts it once", () => {
  const out = html(<ChatSummaryLine summary={{ text: "Parser fixed, CI running.", next: "Merge the PR" }} />);
  expect(out).toContain('class="acpmux-chat-summary"');
  expect(out).toContain('<span class="acpmux-chat-summary__text">Parser fixed, CI running. → Merge the PR</span>');
  expect(out).not.toContain("acpmux-chat-summary__next");
  const full = `Parser fixed, CI running.\n${translate("header.summaryNext", { next: "Merge the PR" })}`;
  expect(full).not.toContain("header.summaryNext");
  expect(out).toContain(`title="${full}"`);
});

test("a summary with no next action draws no arrow", () => {
  const out = html(<ChatSummaryLine summary={{ text: "Menu planned." }} />);
  expect(out).toContain("Menu planned.");
  expect(out).not.toContain("→");
  expect(out).toContain('title="Menu planned."');
});

test("no summary, or a blank one, draws nothing", () => {
  expect(html(<ChatSummaryLine summary={undefined} />)).toBe("");
  expect(html(<ChatSummaryLine summary={null} />)).toBe("");
  expect(html(<ChatSummaryLine summary={{ text: "   ", next: "Go" }} />)).toBe("");
});

// Leo, 2026-11-22: "the icons on the top right have gotten displaced due to putting things on a line" and "why do we
// have this subheading here ... it's overlapping". The tab row's tools slot (`data-tab-row-slot="tools"`) is what the
// page measures for the native strip (header/tabRow.ts useTabRowTools); the pane drops the tools to a second row when
// that width is more than half the room. The summary line is up to 300px of text, so it lives in the header's own row.
test("the summary line is never inside the tab row's measured tools slot", () => {
  const source = readFileSync(path.join(import.meta.dir, "../pane/PaneBody.tsx"), "utf8");
  const open = source.indexOf('data-tab-row-slot="tools"');
  expect(open).toBeGreaterThan(0);
  const close = source.indexOf("</header>", open);
  expect(source.slice(open, close)).not.toContain("<ChatSummaryLine");
  expect(source.slice(0, open)).toContain("<ChatSummaryLine");
});

test("the pane's summary keeps acpmux's rollingSummary, trimmed, and drops a blank one", () => {
  expect(
    rollingSummaryOf({ text: " Parser fixed. ", next: " Merge the PR ", source: "model", turn: 3, at: 1 }),
  ).toEqual({
    rollingSummary: { text: "Parser fixed.", next: "Merge the PR" },
  });
  expect(rollingSummaryOf({ text: "Done.", next: "  " })).toEqual({ rollingSummary: { text: "Done." } });
  expect(rollingSummaryOf({ text: "  " })).toEqual({});
  expect(rollingSummaryOf(undefined)).toEqual({});
});
