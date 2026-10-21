// A `cmux://agent/<harness>/<session>?message=<id>` link opens the chat and scrolls to that one
// message (schemas/deeplinks/agent-link.json). The app hands the page the reveal as
// `message:<id>` on the same channel a turn and a subagent use (links.ts, subagentPanes.ts).
// The transcript virtualizes its rows, so the reveal asks the transcript for the row by its place
// in the chat (App.tsx `showMessage`) and marks it once it is drawn; the id is the harness message
// id acpmux reports on the message's chunks, so a link that names a message this session never saw
// must leave the view exactly where it is.
import { describe, expect, test } from "bun:test";
import { Window } from "happy-dom";
import {
  MESSAGE_REVEAL,
  REVEALED_TURN_CLASS,
  revealMessageWhenShown,
  revealedMessage,
  scrollToRow,
} from "../src/agent-session/acpmux/links";

function transcript(rowIds: string[]) {
  const window = new Window();
  const document = window.document;
  document.body.innerHTML = rowIds.map((id) => `<div data-row-id="${id}">row</div>`).join("");
  const scrolled: string[] = [];
  for (const row of document.querySelectorAll("[data-row-id]")) {
    (row as unknown as { scrollIntoView: () => void }).scrollIntoView = () => {
      scrolled.push((row as unknown as HTMLElement).dataset.rowId ?? "");
    };
  }
  return { root: document as unknown as ParentNode, scrolled, document };
}

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
    expect(scrolled).toEqual(["assistant-2"]);
    expect(document.querySelector('[data-row-id="assistant-2"]')?.classList.contains(REVEALED_TURN_CLASS)).toBe(true);
  });

  test("a row the transcript scrolls to but has not mounted is marked once it is", async () => {
    // What virtualization does: the transcript scrolls by the row's place, and the element appears
    // a frame or two later. The reveal has already answered by then.
    const { root, scrolled, document } = transcript(["user-1"]);

    expect(await revealMessageWhenShown("msg_01", () => "assistant-9", root, { waitMs: 300, pollMs: 10 })).toBe(true);
    expect(scrolled).toEqual([]);

    const body = document.body as unknown as { innerHTML: string };
    body.innerHTML += '<div data-row-id="assistant-9">row</div>';
    const row = document.querySelector('[data-row-id="assistant-9"]');
    (row as unknown as { scrollIntoView: () => void }).scrollIntoView = () => scrolled.push("assistant-9");

    await new Promise((resolve) => setTimeout(resolve, 60));
    expect(scrolled).toEqual(["assistant-9"]);
    expect(row?.classList.contains(REVEALED_TURN_CLASS)).toBe(true);
  });

  test("scrolls to a row by id, and to nothing for an id no row carries", () => {
    const { root, scrolled } = transcript(["assistant-2"]);

    expect(scrollToRow("assistant-2", root)).toBe(true);
    expect(scrollToRow("assistant-3", root)).toBe(false);
    expect(scrolled).toEqual(["assistant-2"]);
  });

  test("waits for the message the transcript has not replayed yet", async () => {
    const { root, scrolled } = transcript(["assistant-2"]);
    let row: string | undefined;

    const revealed = revealMessageWhenShown("msg_01", () => row, root, { waitMs: 2000, pollMs: 10 });
    row = "assistant-2";

    expect(await revealed).toBe(true);
    expect(scrolled).toEqual(["assistant-2"]);
  });

  test("gives up quietly when the message never arrives", async () => {
    const { root, scrolled } = transcript(["assistant-2"]);

    expect(await revealMessageWhenShown("msg_01", () => undefined, root, { waitMs: 30, pollMs: 10 })).toBe(false);
    expect(scrolled).toEqual([]);
  });
});
