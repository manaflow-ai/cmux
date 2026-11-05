// A `cmux://agent/<harness>/<session>?message=<id>` link opens the chat and scrolls to that one
// message (schemas/deeplinks/agent-link.json). The app hands the page the reveal as
// `message:<id>` on the same channel a turn and a subagent use (links.ts, subagentPanes.ts).
// The transcript virtualizes its rows, so the reveal asks the transcript for the row by its place
// in the chat (App.tsx `showMessage`) and marks it once it is drawn; the id is the harness message
// id acpmux reports on the message's chunks, so a link that names a message this session never saw
// must leave the view exactly where it is.
import { describe, expect, jest, test } from "bun:test";
import { Window } from "happy-dom";
import {
  MESSAGE_REVEAL,
  REVEALED_TURN_CLASS,
  notifyRevealRowsChanged,
  revealMessageWhenShown,
  revealedMessage,
  scrollToRow,
} from "../src/agent-session/acpmux/links";
import { findRowIndex } from "../src/agent-session/acpmux/conversation/chatFind";
import { messageRevealTarget, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { userScrollIntent } from "../src/agent-session/acpmux/conversation/userScroll";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

function transcript(rowIds: string[]) {
  const window = new Window();
  const document = window.document;
  document.body.innerHTML = `<div class="acpmux-scroll">${rowIds.map((id) => `<div data-row-id="${id}">row</div>`).join("")}</div>`;
  const scrolled: string[] = [];
  for (const row of document.querySelectorAll("[data-row-id]")) {
    (row as unknown as { scrollIntoView: () => void }).scrollIntoView = () => {
      scrolled.push((row as unknown as HTMLElement).dataset.rowId ?? "");
    };
  }
  const scroller = document.querySelector(".acpmux-scroll")!;
  return { root: document as unknown as ParentNode, scrolled, document, window, scroller };
}

// Only the wait deadline uses a timer; mounted rows are reported by the DOM's mutation observer.
const onFakeClock = (body: () => Promise<void>) => async () => {
  jest.useFakeTimers();
  try {
    await body();
  } finally {
    jest.useRealTimers();
  }
};
describe("revealing one message", () => {
  test("names the message on the reveal channel", () => {
    expect(revealedMessage(`${MESSAGE_REVEAL}msg_01`)).toBe("msg_01");
    expect(revealedMessage("turn_7")).toBeUndefined();
    expect(revealedMessage("subagent:a")).toBeUndefined();
    expect(revealedMessage(MESSAGE_REVEAL)).toBeUndefined();
  });

  test("asks the transcript for the message's row, then marks the row it drew", async () => {
    const { root, scrolled, document } = transcript(["user-1", "assistant-2"]);
    const asked: string[] = [];

    const revealed = await revealMessageWhenShown(
      "msg_01",
      (id) => {
        asked.push(id);
        return "assistant-2";
      },
      root,
      { waitMs: 200, pollMs: 10 },
    );

    expect(revealed).toBe(true);
    expect(asked).toEqual(["msg_01"]);
    expect(scrolled).toEqual([]);
    expect(document.querySelector('[data-row-id="assistant-2"]')?.classList.contains(REVEALED_TURN_CLASS)).toBe(true);
  });

  test(
    "a row the transcript scrolls to but has not mounted is marked once it is",
    onFakeClock(async () => {
      // What virtualization does: the transcript scrolls by the row's place, and the element appears
      // a frame or two later. The reveal has already answered by then.
      const { root, scrolled, document, window, scroller } = transcript(["user-1"]);

      expect(
        await revealMessageWhenShown("msg_01", () => "assistant-9", root, {
          waitMs: 300,
          pollMs: 10,
        }),
      ).toBe(true);
      expect(scrolled).toEqual([]);

      scroller.insertAdjacentHTML("beforeend", '<div data-row-id="assistant-9">row</div>');
      const row = document.querySelector('[data-row-id="assistant-9"]');
      (row as unknown as { scrollIntoView: () => void }).scrollIntoView = () => scrolled.push("assistant-9");

      await new Promise<void>((resolve) => window.queueMicrotask(resolve));
      expect(scrolled).toEqual([]);
      expect(row?.classList.contains(REVEALED_TURN_CLASS)).toBe(true);
    }),
  );

  test("marks the mounted copy inside an open fold without another scroll", async () => {
    const { root, scrolled, document } = transcript(["assistant-2:fold"]);

    expect(await revealMessageWhenShown("msg_01", () => "assistant-2", root)).toBe(true);
    expect(scrolled).toEqual([]);
    expect(document.querySelector('[data-row-id="assistant-2:fold"]')?.classList.contains(REVEALED_TURN_CLASS)).toBe(
      true,
    );
  });

  test(
    "manual input cancels a row's pending highlight",
    onFakeClock(async () => {
      const { root, scrolled, document, window, scroller } = transcript(["user-1"]);

      expect(await revealMessageWhenShown("msg_01", () => "assistant-9", root, { waitMs: 300 })).toBe(true);
      userScrollIntent(scroller as unknown as HTMLElement).mark();
      scroller.insertAdjacentHTML("beforeend", '<div data-row-id="assistant-9">row</div>');
      const row = document.querySelector('[data-row-id="assistant-9"]');
      (row as unknown as { scrollIntoView: () => void }).scrollIntoView = () => scrolled.push("assistant-9");

      await new Promise<void>((resolve) => window.queueMicrotask(resolve));
      expect(scrolled).toEqual([]);
      expect(row?.classList.contains(REVEALED_TURN_CLASS)).toBe(false);
    }),
  );

  test(
    "an unmounted row does no repeated scanning and stops waiting at its deadline",
    onFakeClock(async () => {
      const { root, document, window, scroller } = transcript(["user-1"]);
      const scan = jest.spyOn(root, "querySelectorAll");
      try {
        expect(
          await revealMessageWhenShown("msg_01", () => "assistant-9", root, {
            waitMs: 300,
            pollMs: 10,
          }),
        ).toBe(true);
        const initialScans = scan.mock.calls.length;
        jest.advanceTimersByTime(200);
        expect(scan.mock.calls.length).toBe(initialScans);
        jest.advanceTimersByTime(100);
        scroller.insertAdjacentHTML("beforeend", '<div data-row-id="assistant-9">row</div>');
        await new Promise<void>((resolve) => window.queueMicrotask(resolve));
        expect(scan.mock.calls.length).toBe(initialScans);
        expect(document.querySelector('[data-row-id="assistant-9"]')?.classList.contains(REVEALED_TURN_CLASS)).toBe(
          false,
        );
      } finally {
        scan.mockRestore();
      }
    }),
  );

  test("scrolls to a row by id, and to nothing for an id no row carries", () => {
    const { root, scrolled } = transcript(["assistant-2"]);

    expect(scrollToRow("assistant-2", root)).toBe(true);
    expect(scrollToRow("assistant-3", root)).toBe(false);
    expect(scrolled).toEqual(["assistant-2"]);
  });

  test("scrolls to the copy an open fold draws of the row, which is the same row to a reader", () => {
    const { root, scrolled } = transcript(["user-1", "assistant-2:fold"]);

    expect(scrollToRow("assistant-2", root)).toBe(true);
    expect(scrolled).toEqual(["assistant-2:fold"]);
  });
});

/// A turn where the reply worked: the first half of the answer, a tool call, then the rest. Only
/// the last row stays out of the turn's "Worked for" fold.
function workedTurn(): AcpmuxRow[] {
  let at = 0;
  const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    kind,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  return [
    row("user-1", "user", { text: "Are the tests green?" }),
    row("assistant-2", "assistant", { text: "Let me check the tests." }),
    row("activity-3", "activity", {
      items: [{ kind: "tool", text: "", tool: { id: "bash-1", title: "bun test", status: "completed" } }],
    }),
    row("assistant-4", "assistant", { text: "All green." }),
    row("turn-5", "turnSummary", { status: "completed", durationMs: 1_000 }),
  ];
}

describe("where a revealed message's row is", () => {
  const drawn = (rows: AcpmuxRow[], expanded: ReadonlySet<string> = new Set()) =>
    turnView(rows, expanded, { now: 10_000 });

  test("opens the turn's fold for a message whose every row the fold hides", () => {
    // What a message that worked looks like: a tool call ends the reply it interrupts, so the
    // message's first row is folded and the transcript cannot scroll to it as it stands.
    const rows = workedTurn();
    const shown = drawn(rows);
    expect(findRowIndex(shown, "assistant-2")).toBe(-1);

    expect(messageRevealTarget(rows, shown, ["assistant-2"])).toEqual({
      rowId: "assistant-2",
      fold: "worked-user-1",
    });

    // With that fold open the row is drawn, so there is nothing left to open.
    const opened = drawn(rows, new Set(["worked-user-1"]));
    expect(findRowIndex(opened, "assistant-2")).toBeGreaterThanOrEqual(0);
    expect(messageRevealTarget(rows, opened, ["assistant-2"])).toEqual({ rowId: "assistant-2" });
  });

  test("takes the message's drawn row over a folded one, and opens nothing", () => {
    // One message, two rows: the chunk before the tool call and the turn's answer after it.
    const rows = workedTurn();

    expect(messageRevealTarget(rows, drawn(rows), ["assistant-2", "assistant-4"])).toEqual({
      rowId: "assistant-4",
    });
  });

  test("leaves the view alone for a message none of the chat's rows carry", () => {
    const rows = workedTurn();

    expect(messageRevealTarget(rows, drawn(rows), [])).toBeUndefined();
    expect(messageRevealTarget(rows, drawn(rows), ["assistant-9"])).toBeUndefined();
  });

  test("waits for the message the transcript has not replayed yet", async () => {
    const { root, scrolled } = transcript(["assistant-2"]);
    let row: string | undefined;

    const revealed = revealMessageWhenShown("msg_01", () => row, root, {
      waitMs: 2000,
      pollMs: 10,
    });
    row = "assistant-2";
    notifyRevealRowsChanged();

    expect(await revealed).toBe(true);
    expect(scrolled).toEqual([]);
  });

  test(
    "a later reveal stops the earlier one's row from pulling the view back",
    onFakeClock(async () => {
      const { root, scrolled, document, window, scroller } = transcript(["user-1"]);

      expect(
        await revealMessageWhenShown("msg_01", () => "assistant-1", root, {
          waitMs: 300,
          pollMs: 10,
        }),
      ).toBe(true);
      expect(await revealMessageWhenShown("msg_02", () => "user-1", root, { waitMs: 300, pollMs: 10 })).toBe(true);
      expect(scrolled).toEqual([]);
      expect(document.querySelector('[data-row-id="user-1"]')?.classList.contains(REVEALED_TURN_CLASS)).toBe(true);

      // The first link's row is drawn after the reader has already been taken to the second's.
      scroller.insertAdjacentHTML("beforeend", '<div data-row-id="assistant-1">row</div>');
      const late = document.querySelector('[data-row-id="assistant-1"]');
      (late as unknown as { scrollIntoView: () => void }).scrollIntoView = () => scrolled.push("assistant-1");

      await new Promise<void>((resolve) => window.queueMicrotask(resolve));
      expect(scrolled).toEqual([]);
      expect(late?.classList.contains(REVEALED_TURN_CLASS)).toBe(false);
    }),
  );

  test(
    "a row the reader left behind is dropped, not scrolled into the chat they moved to",
    onFakeClock(async () => {
      // Row ids start over with each session (`assistant-<seq>`), so the id of a row still waiting to
      // be drawn can belong to an unrelated row in the chat the pane has moved to.
      const { root, scrolled, document, window, scroller } = transcript(["user-1"]);
      let chat: string | undefined = "session-a";

      expect(
        await revealMessageWhenShown("msg_01", () => "assistant-9", root, {
          waitMs: 300,
          pollMs: 10,
          chat: () => chat,
        }),
      ).toBe(true);
      expect(scrolled).toEqual([]);

      chat = "session-b";
      scroller.insertAdjacentHTML("beforeend", '<div data-row-id="assistant-9">another chat\'s row</div>');
      const other = document.querySelector('[data-row-id="assistant-9"]');
      (other as unknown as { scrollIntoView: () => void }).scrollIntoView = () => scrolled.push("assistant-9");

      await new Promise<void>((resolve) => window.queueMicrotask(resolve));
      expect(scrolled).toEqual([]);
      expect(other?.classList.contains(REVEALED_TURN_CLASS)).toBe(false);
    }),
  );

  test("gives up quietly when the message never arrives", async () => {
    const { root, scrolled } = transcript(["assistant-2"]);

    expect(await revealMessageWhenShown("msg_01", () => undefined, root, { waitMs: 30, pollMs: 10 })).toBe(false);
    expect(scrolled).toEqual([]);
  });
});
