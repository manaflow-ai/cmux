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

  test("only the latest completed turn forks: acpmux forks a chat at its end, not through an earlier turn", () => {
    const ended = snapshot({
      rows: [
        row("p1", "user", { text: "one" }),
        row("a1", "assistant", { text: "First." }),
        row("s1", "turnSummary", { seq: 41 }),
        row("p2", "user", { text: "two" }),
        row("a2", "assistant", { text: "Second." }),
        row("s2", "turnSummary", { seq: 57 }),
      ],
    });
    expect(messageMenuTarget(ended, "a1")?.forkSeq).toBeUndefined();
    expect(messageMenuTarget(ended, "p1")?.forkSeq).toBeUndefined();
    expect(messageMenuTarget(ended, "a2")?.forkSeq).toBe(57);
    expect(messageMenuTarget(ended, "p2")?.forkSeq).toBe(57);
    // acpmux refuses a fork while a turn runs or for a chat on another computer.
    expect(messageMenuTarget({ ...ended, isWorking: true }, "a2")?.forkSeq).toBeUndefined();
  });

  test("a folded copy is its message; other rows are not messages", () => {
    expect(messageMenuTarget(snapshot(), "a1:fold")?.markdown).toBe("Fixed in `main.rs`:\n\n- one\n- two");
    expect(messageMenuTarget(snapshot(), "s1")).toBeUndefined();
    expect(messageMenuTarget(snapshot(), "missing")).toBeUndefined();
  });

  test("a prompt that was not sent offers Retry through its row", () => {
    const failed = snapshot({ rows: [row("p9", "user", { text: "deploy", failed: true })] });
    expect(messageMenuTarget(failed, "p9")).toEqual({ text: "deploy", retryRowId: "p9" });
  });

  test("a message's web links and images open from the menu, each once, in reading order", () => {
    const linked = snapshot({
      rows: [
        row("a7", "assistant", {
          text: "See [the docs](https://cmux.dev/docs) and ![chart](https://cmux.dev/chart.png), again [docs](https://cmux.dev/docs). [x](javascript:alert(1))",
        }),
        row("p7", "user", { text: "why does https://example.com/a fail?" }),
      ],
    });
    expect(messageMenuTarget(linked, "a7")?.links).toEqual(["https://cmux.dev/docs", "https://cmux.dev/chart.png"]);
    expect(messageMenuTarget(linked, "p7")?.links).toEqual(["https://example.com/a"]);
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

  test("a right-click inside selected transcript text reports the selection; outside it or in the composer, not", () => {
    setMessageMenuSource((rowId) => messageMenuTarget(snapshot(), rowId));
    const dom = new JSDOM(
      '<article data-row-id="a1"><p><b id="inside">Fixed</b> it</p></article><div id="outside">x</div>' +
        '<div contenteditable="true"><span id="draft">my draft</span></div>',
    );
    const doc = dom.window.document;
    const posted: unknown[] = [];
    installMessageMenuReporter(doc, () => ({ postMessage: (body) => posted.push(body) }));
    const select = (id: string) => {
      const range = doc.createRange();
      range.selectNodeContents(doc.getElementById(id)!);
      dom.window.getSelection()!.removeAllRanges();
      dom.window.getSelection()!.addRange(range);
    };
    const rightClick = (id: string) =>
      doc.getElementById(id)!.dispatchEvent(new dom.window.MouseEvent("contextmenu", { bubbles: true }));
    select("inside");
    rightClick("inside");
    rightClick("outside");
    select("draft");
    rightClick("draft");
    expect(posted).toEqual([
      {
        text: "Fixed in main.rs:\n\n- one\n- two",
        markdown: "Fixed in `main.rs`:\n\n- one\n- two",
        forkSeq: 41,
        selection: "Fixed",
      },
      null,
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
      {
        text: "Fixed in main.rs:\n\n- one\n- two",
        markdown: "Fixed in `main.rs`:\n\n- one\n- two",
        forkSeq: 41,
        openImage: true,
      },
      null,
    ]);
    expect(opened).toEqual(["tile", "reply-image"]);
    setMessageMenuSource(undefined);
  });
});
