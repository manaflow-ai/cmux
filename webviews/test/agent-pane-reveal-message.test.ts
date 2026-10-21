// A `cmux://agent/<harness>/<session>?message=<id>` link opens the chat and scrolls to that one
// message (schemas/deeplinks/agent-link.json). The app hands the page the reveal as
// `message:<id>` on the same channel a turn and a subagent use (links.ts, subagentPanes.ts).
// The id is the harness message id acpmux reports on the message's chunks, so a link that names
// a message this session never saw must leave the view exactly where it is.
import { describe, expect, test } from "bun:test";
import { Window } from "happy-dom";
import {
  MESSAGE_REVEAL,
  REVEALED_TURN_CLASS,
  revealMessageWhenShown,
  revealedMessage,
  scrollToMessage,
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

  test("scrolls to the message's first row and marks it", () => {
    const { root, scrolled, document } = transcript(["user-1", "assistant-2", "assistant-5"]);
    const rows = { msg_01: ["assistant-2", "assistant-5"] };

    expect(scrollToMessage("msg_01", (id) => rows[id as keyof typeof rows] ?? [], root)).toBe(true);
    expect(scrolled).toEqual(["assistant-2"]);
    expect(document.querySelector('[data-row-id="assistant-2"]')?.classList.contains(REVEALED_TURN_CLASS)).toBe(true);
  });

  test("a message with no row on screen moves nothing", () => {
    const { root, scrolled } = transcript(["user-1", "assistant-2"]);

    expect(scrollToMessage("msg_missing", () => [], root)).toBe(false);
    expect(scrollToMessage("msg_01", () => ["assistant-9"], root)).toBe(false);
    expect(scrolled).toEqual([]);
  });

  test("scrolls to a row by id, and to nothing for an id no row carries", () => {
    const { root, scrolled } = transcript(["assistant-2"]);

    expect(scrollToRow("assistant-2", root)).toBe(true);
    expect(scrollToRow("assistant-3", root)).toBe(false);
    expect(scrolled).toEqual(["assistant-2"]);
  });

  test("waits for the row the transcript has not replayed yet", async () => {
    const { root, scrolled } = transcript(["assistant-2"]);
    let rows: string[] = [];

    const revealed = revealMessageWhenShown("msg_01", () => rows, root, {
      waitMs: 2000,
      pollMs: 10,
    });
    rows = ["assistant-2"];

    expect(await revealed).toBe(true);
    expect(scrolled).toEqual(["assistant-2"]);
  });

  test("gives up quietly when the message never arrives", async () => {
    const { root, scrolled } = transcript(["assistant-2"]);

    expect(await revealMessageWhenShown("msg_01", () => [], root, { waitMs: 30, pollMs: 10 })).toBe(false);
    expect(scrolled).toEqual([]);
  });
});
