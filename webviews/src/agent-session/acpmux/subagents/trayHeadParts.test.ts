// l10n-allow-file: test commands, not shipped UI.
// The running tray header's kinds (trayHeadKinds.ts `trayHeadParts`): Leo, 2026-11-21, on a coordinator's
// tray that read "pgrep · head · ps" folded and "1 message · 1 wait" open: the open header "almost
// makes more sense to have at baseline", each kind with its icon to hover across.
import { expect, test } from "bun:test";
import { translate } from "../i18n";
import { trayHead, trayHeadParts } from "./trayHeadKinds";
import { trayItems } from "./runningTray";
import type { BackgroundCommand } from "../session-info/processes";

const command = (id: string, line: string): BackgroundCommand => ({
  id,
  command: line,
  state: "running",
  processId: `proc-${id}`,
  startedAt: 1_794_000_000_000,
});

const commands = [
  command("send", 'acpmux send studio-mac/review "status?"'),
  command("wait", "gh pr checks 1234 --watch"),
];

test("each kind has its mark, its count and the items it counts", () => {
  const items = trayItems([], commands, [], true);
  const parts = trayHeadParts(translate, { items, finished: [], waiting: new Set() });
  expect(parts.map((part) => [part.key, part.icon, part.text, part.items.length])).toEqual([
    ["sends", "agent.chat", "1 message", 1],
    ["waits", "history", "1 wait", 1],
  ]);
});

test("the kinds read as the counts do", () => {
  const items = trayItems([], [...commands, command("ps", "pgrep -f nightly | head -3; ps -o etime= -p 1")], [], true);
  const args = { items, finished: [], waiting: new Set<string>(), working: true };
  const head = trayHead(translate, { ...args, chatHarness: "claude", arm: "kinds" });
  expect(
    trayHeadParts(translate, args)
      .map((part) => part.text)
      .join(" · "),
  ).toBe(head.text);
});

test("nothing running draws no kinds", () => {
  expect(trayHeadParts(translate, { items: [], finished: [], waiting: new Set() })).toEqual([]);
});
