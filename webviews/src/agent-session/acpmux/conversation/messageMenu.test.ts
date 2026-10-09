import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import {
  installMessageMenuReporter,
  messageMenuTarget,
  openReportedImage,
  plainText,
  setMessageMenuSource,
} from "./messageMenu";

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind,
  ...extra,
});

const snapshot = (extra: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot => ({
  type: "snapshot",
  protocolVersion: 1,
  rows: [
    row("p1", "user", { text: "fix the **build**" }),
    row("a1", "assistant", { text: "Fixed in `main.rs`:\n\n- one\n- two" }),
    row("s1", "turnSummary", { seq: 41 }),
    row("p2", "user", { text: "and the tests" }),
    row("a2", "assistant", { text: "Running them." }),
  ],
  sessions: [],
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
  canFork: true,
  ...extra,
});

describe("the agent pane's context menu target", () => {
  test("an agent reply copies as read and as Markdown, and forks through its turn", () => {
    expect(messageMenuTarget(snapshot(), "a1")).toEqual({
      text: "Fixed in main.rs:\n\n- one\n- two",
      markdown: "Fixed in `main.rs`:\n\n- one\n- two",
      forkSeq: 41,
    });
  });

  test("a prompt copies as typed, with its turn's fork point", () => {
    expect(messageMenuTarget(snapshot(), "p1")).toEqual({ text: "fix the **build**", forkSeq: 41 });
  });

  test("a turn that has not ended, or a pane that cannot fork, offers no fork", () => {
    expect(messageMenuTarget(snapshot(), "a2")).toEqual({ text: "Running them.", markdown: "Running them." });
    expect(messageMenuTarget(snapshot({ canFork: false }), "a1")?.forkSeq).toBeUndefined();
    expect(messageMenuTarget(snapshot({ connection: "disconnected" }), "a1")?.forkSeq).toBeUndefined();
  });

  test("a folded copy is its message; other rows are not messages", () => {
    expect(messageMenuTarget(snapshot(), "a1:fold")?.markdown).toBe("Fixed in `main.rs`:\n\n- one\n- two");
    expect(messageMenuTarget(snapshot(), "s1")).toBeUndefined();
    expect(messageMenuTarget(snapshot(), "missing")).toBeUndefined();
  });

  test("plain text drops Markdown syntax but keeps code, links' text and list order", () => {
    expect(
      plainText(
        "# Title\n\nSee [the docs](https://x.dev) and *this*.\n\n```ts\nconst a = 1;\n```\n\n1. first\n2. second",
      ),
    ).toBe("Title\n\nSee the docs and this.\n\nconst a = 1;\n\n1. first\n2. second");
  });
});

describe("the page's report on contextmenu", () => {
  const page = () => {
    const dom = new JSDOM(
      '<article data-row-id="a1"><p><b id="inside">Fixed</b></p>' +
        '<button data-open-image id="reply-image"><img id="reply-img"></button></article>' +
        '<div id="outside"></div><button data-open-image id="tile"><img id="tile-img"></button>',
    );
    const posted: unknown[] = [];
    const remove = installMessageMenuReporter(dom.window.document, () => ({
      postMessage: (body) => posted.push(body),
    }));
    const rightClick = (id: string) =>
      dom.window.document
        .getElementById(id)!
        .dispatchEvent(new dom.window.MouseEvent("contextmenu", { bubbles: true }));
    return { dom, posted, remove, rightClick };
  };

  test("a right-click on a message reports it, anywhere else reports null", () => {
    setMessageMenuSource((rowId) => messageMenuTarget(snapshot(), rowId));
    const { posted, remove, rightClick } = page();
    rightClick("inside");
    rightClick("outside");
    remove();
    rightClick("inside");
    expect(posted).toEqual([
      { text: "Fixed in main.rs:\n\n- one\n- two", markdown: "Fixed in `main.rs`:\n\n- one\n- two", forkSeq: 41 },
      null,
    ]);
    setMessageMenuSource(undefined);
  });

  test("before the client connects every report is null", () => {
    const { posted, rightClick } = page();
    rightClick("inside");
    expect(posted).toEqual([null]);
  });

  // POLISH right-click contract (Leo 2026-10-08): an image in the chat or its gallery offers Open
  // Image, which opens it as its click does.
  test("a right-click on an image reports it, and Open Image clicks it", () => {
    setMessageMenuSource((rowId) => messageMenuTarget(snapshot(), rowId));
    const { dom, posted, remove, rightClick } = page();
    const opened: string[] = [];
    for (const id of ["reply-image", "tile"])
      dom.window.document.getElementById(id)!.addEventListener("click", () => opened.push(id));
    rightClick("tile-img");
    expect(openReportedImage()).toBe(true);
    rightClick("reply-img");
    expect(openReportedImage()).toBe(true);
    rightClick("outside");
    expect(openReportedImage()).toBe(false);
    remove();
    expect(posted).toEqual([
      { openImage: true },
      { text: "Fixed in main.rs:\n\n- one\n- two", markdown: "Fixed in `main.rs`:\n\n- one\n- two", forkSeq: 41, openImage: true },
      null,
    ]);
    expect(opened).toEqual(["tile", "reply-image"]);
    setMessageMenuSource(undefined);
  });
});
