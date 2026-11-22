// l10n-allow-file: test fixture summaries, not shipped UI.
// The chat header's rolling summary (ChatSummaryLine.tsx): the daemon's `rollingSummary` beside the
// chat's name, its next action after an arrow, the whole text as its tooltip; nothing before the
// first summary.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { rollingSummaryOf } from "../direct";
import { translate } from "../i18n";
import { ChatSummaryLine } from "./ChatSummaryLine";

const html = (node: React.ReactElement) => renderToStaticMarkup(node);

test("a summary with a next action reads as the summary, an arrow and the action", () => {
  const out = html(<ChatSummaryLine summary={{ text: "Parser fixed, CI running.", next: "Merge the PR" }} />);
  expect(out).toContain('class="acpmux-chat-summary"');
  expect(out).toContain('<span class="acpmux-chat-summary__text">Parser fixed, CI running.</span>');
  expect(out).toContain('<span class="acpmux-chat-summary__arrow" aria-hidden="true">→</span>');
  expect(out).toContain('<span class="acpmux-chat-summary__next">Merge the PR</span>');
  const full = `Parser fixed, CI running.\n${translate("header.summaryNext", { next: "Merge the PR" })}`;
  expect(full).toContain("Merge the PR");
  expect(full).not.toContain("header.summaryNext");
  expect(out).toContain(`title="${full}"`);
});

test("a summary with no next action draws no arrow", () => {
  const out = html(<ChatSummaryLine summary={{ text: "Menu planned." }} />);
  expect(out).toContain("Menu planned.");
  expect(out).not.toContain("acpmux-chat-summary__arrow");
  expect(out).toContain('title="Menu planned."');
});

test("no summary, or a blank one, draws nothing", () => {
  expect(html(<ChatSummaryLine summary={undefined} />)).toBe("");
  expect(html(<ChatSummaryLine summary={null} />)).toBe("");
  expect(html(<ChatSummaryLine summary={{ text: "   ", next: "Go" }} />)).toBe("");
});

test("the tab-row header's copy is the inline variant", () => {
  const out = html(<ChatSummaryLine summary={{ text: "Done." }} inline />);
  expect(out).toContain('class="acpmux-chat-summary acpmux-chat-summary--inline"');
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
