import { describe, expect, it } from "bun:test";
import type { HomeMessage } from "../../home-channels/types";
import { bubbleStyle, readableText } from "./colors";
import { ComposerHistory, historyEntries, historyTakesArrow } from "./history";
import { hasText, intakeProblem, textBeside, type TransferLike } from "./intake";

const sent = (id: number, text: string, author = "me", retracted = false): HomeMessage => ({
  id: `m${id}`,
  conversation: "c1",
  seq: id,
  author,
  createdAt: id,
  retracted,
  parts: [{ type: "text", text, mentions: [] }],
  reactions: [],
});

describe("history (ComposerHistory.swift)", () => {
  const entries = () => historyEntries([sent(1, "first ask"), sent(2, "second ask"), sent(3, "third ask")], "me");

  it("recalls the newest then older sent messages, and stays at the oldest", () => {
    const history = new ComposerHistory();
    expect(history.step("older", "", entries)).toBe("third ask");
    expect(history.step("older", "third ask", entries)).toBe("second ask");
    expect(history.step("older", "second ask", entries)).toBe("first ask");
    expect(history.step("older", "first ask", entries)).toBeUndefined();
  });

  it("gives the typed draft back on Down from the newest", () => {
    const history = new ComposerHistory();
    history.step("older", "half typed", entries);
    history.step("older", "third ask", entries);
    expect(history.step("newer", "second ask", entries)).toBe("third ask");
    expect(history.step("newer", "third ask", entries)).toBe("half typed");
    expect(history.step("newer", "half typed", entries)).toBeUndefined();
  });

  it("ends the browse when the recalled text is edited", () => {
    const history = new ComposerHistory();
    history.step("older", "", entries);
    history.textChanged("third ask again");
    expect(history.isBrowsing).toBe(false);
    expect(history.step("newer", "third ask again", entries)).toBeUndefined();
  });

  it("keeps only my live text messages, newest first, without repeats", () => {
    const list = [
      sent(1, "a"),
      sent(2, "b"),
      sent(3, "b"),
      sent(4, "x", "ana"),
      sent(5, "gone", "me", true),
      sent(6, " "),
    ];
    expect(historyEntries(list, "me")).toEqual(["b", "a"]);
  });

  it("takes Up only on the first line and Down only on the last", () => {
    expect(historyTakesArrow("older", "line one\nline two", 17)).toBe(false);
    expect(historyTakesArrow("older", "line one\nline two", 3)).toBe(true);
    expect(historyTakesArrow("newer", "line one\nline two", 3)).toBe(false);
    expect(historyTakesArrow("newer", "line one\nline two", 12)).toBe(true);
  });
});

function transfer(data: Record<string, string>, files: File[] = []): TransferLike {
  return {
    files,
    types: [...Object.keys(data), ...(files.length ? ["Files"] : [])],
    getData: (type) => data[type] ?? "",
  };
}

describe("paste and drop (HomeAttachmentIntake.swift)", () => {
  it("reads words as text, and a lone link or blank as no text", () => {
    expect(hasText(transfer({ "text/plain": "hello there" }))).toBe(true);
    expect(hasText(transfer({ "text/plain": "https://example.com/a.png" }))).toBe(false);
    expect(hasText(transfer({ "text/plain": "   " }))).toBe(false);
    expect(hasText(transfer({ "text/plain": "word" }))).toBe(true);
    // A spreadsheet cell: rich text with a lone link not marked as a URL is text.
    expect(hasText(transfer({ "text/plain": "https://example.com", "text/html": "<td>x</td>" }))).toBe(true);
    expect(
      hasText(
        transfer({ "text/plain": "https://example.com", "text/html": "<a>", "text/uri-list": "https://example.com" }),
      ),
    ).toBe(false);
  });

  it("drops a copied file's own name, and keeps real words beside files", () => {
    const file = new File(["x"], "shot.png", { type: "image/png" });
    expect(textBeside(transfer({ "text/plain": "shot.png" }, [file]))).toBeUndefined();
    expect(textBeside(transfer({ "text/plain": "/Users/x/shot.png" }, [file]))).toBeUndefined();
    expect(textBeside(transfer({ "text/plain": "see this one" }, [file]))).toBe("see this one");
  });

  it("refuses an empty file (a folder) by name, a pasted one as the pasted item", () => {
    expect(intakeProblem(new File([], "Folder"), "Pasted item")).toEqual({ kind: "empty", name: "Folder" });
    expect(intakeProblem(new File([], ""), "Pasted item")).toEqual({ kind: "empty", name: "Pasted item" });
    expect(intakeProblem(new File(["x"], "a.txt"), "Pasted item")).toBeUndefined();
  });
});

describe("chat colours", () => {
  it("picks readable text on a chosen bubble and keeps a chosen text colour", () => {
    expect(readableText("#0A84FF")).toBe("#ffffff");
    expect(readableText("#FFD60A")).toBe("#000000");
    expect(bubbleStyle({ sent: "#FFD60A" }) as Record<string, string>).toEqual({
      "--mt-sent": "#FFD60A",
      "--mt-sent-text": "#000000",
    });
    expect(bubbleStyle({ received: "#1C2A4A", receivedText: "#ff00aa" }) as Record<string, string>).toEqual({
      "--mt-received": "#1C2A4A",
      "--mt-received-text": "#ff00aa",
    });
    expect(bubbleStyle({ sent: "blue" })).toEqual({});
  });
});
