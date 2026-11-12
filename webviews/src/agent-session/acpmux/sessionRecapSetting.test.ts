// Settings > Chats > Session Recap reaches the chat page (Swift AgentPaneDisplaySetting.followedAppPaths)
// and applies at once: off, recap rows estimate no height (model.ts) and draw nothing (rows/RecapRow.tsx). A recap
// × with no key dismisses the row's own recap, never one keyed "undefined" (#37818).
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "./direct";
import { chatDisplay, SESSION_RECAP_KEY, sessionRecapEnabled, setChatDisplay } from "./chatDisplay";
import { SINCE_DIVIDER, type AcpmuxRow } from "./model";

const recapRow: AcpmuxRow = {
  id: "recap-9",
  version: 1,
  at: 0,
  kind: "recap",
  recap: { key: "s-1:9", text: "The goal is X. Next, Y." },
};

test("the setting turns recaps off and on live, on by default", () => {
  setChatDisplay({});
  expect(sessionRecapEnabled()).toBe(true);
  setChatDisplay({ [SESSION_RECAP_KEY]: false });
  expect(sessionRecapEnabled()).toBe(false);
  setChatDisplay({ [SESSION_RECAP_KEY]: true });
  expect(sessionRecapEnabled()).toBe(true);
  setChatDisplay({});
});

function fakeClient(
  rows: AcpmuxRow[],
  since?: { sessionId: string; seq: number; turns: number; recap?: { key: string; text: string } },
) {
  const self = {
    rows: new Map(rows.map((row) => [row.id, row])),
    since,
    emitted: 0,
    placeSince() {},
    emit() {
      self.emitted++;
    },
  };
  const dismiss = (rowId: string, key?: string) =>
    AcpmuxDirectClient.prototype.dismissRecap.call(self as never, rowId, key);
  return { self, dismiss };
}

test("a toggle makes the transcript measure again, so an off-screen recap keeps no space", () => {
  setChatDisplay({});
  const before = chatDisplay();
  setChatDisplay({ [SESSION_RECAP_KEY]: false });
  expect(chatDisplay()).not.toBe(before);
  expect(chatDisplay()).toEqual(before);
  setChatDisplay({});
});

test("a dismissal with no key drops the row's own recap", () => {
  const { self, dismiss } = fakeClient([recapRow]);
  dismiss("recap-9");
  expect(self.rows.has("recap-9")).toBe(false);
  expect(self.emitted).toBe(1);
});

test("a dismissal with no key on the divider drops the divider's recap", () => {
  const { self, dismiss } = fakeClient([], { sessionId: "s-1", seq: 4, turns: 2, recap: { key: "s-1:9", text: "x" } });
  dismiss(SINCE_DIVIDER);
  expect(self.since?.recap).toBeUndefined();
});

test("a dismissal with no key on a row without a recap does nothing", () => {
  const { self, dismiss } = fakeClient([{ id: "row-1", version: 1, at: 0, kind: "assistant", text: "hi" }]);
  dismiss("row-1");
  expect(self.rows.has("row-1")).toBe(true);
  expect(self.emitted).toBe(0);
});
