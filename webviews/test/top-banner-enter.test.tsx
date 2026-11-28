// l10n-allow-file: test fixture commands, not shipped UI.
// A banner at the top of a page drops in from the top (Leo 2026-10-20, directional motion): the
// agent chat's watched-session and chat-open-elsewhere lines (and its session-missing line, in
// App.tsx), and Settings' read-only line, carry `data-enter="top"`, which ui/popupSurface.css plays once when they mount
// (ui-enter, on the host's motion tokens; Reduce Motion drops the travel, motion off the whole of it).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { LiveChatChoice } from "../src/agent-session/acpmux/LiveChatChoice";
import { WatchBanner } from "../src/agent-session/acpmux/WatchBanner";
import { ReadOnlyBanner } from "../src/pages/settings/components/ReadOnlyBanner";

const enters = (html: string) => /^<[a-z]+ [^>]*data-enter="top"/.test(html);

test("the watched-session banner drops in from the top", () => {
  expect(enters(renderToStaticMarkup(<WatchBanner family="claude" onTakeOver={() => {}} />))).toBe(true);
});

test("the chat-open-elsewhere line drops in from the top", () => {
  const html = renderToStaticMarkup(<LiveChatChoice canFork command="claude --resume 3f2b" onChoose={() => {}} />);
  expect(enters(html)).toBe(true);
});

test("Settings' failed-read banner drops in from the top; a lost link is a corner mark that does not", () => {
  expect(enters(renderToStaticMarkup(<ReadOnlyBanner reason="loadFailed" />))).toBe(true);
  // A lost link takes no room, so the rows never move (ReadOnlyBanner.tsx, ui/ConnectionChip.tsx).
  const lost = renderToStaticMarkup(<ReadOnlyBanner />);
  expect(lost).toContain('data-read-only="disconnected"');
  expect(enters(lost)).toBe(false);
});
