import { describe, expect, it, mock } from "bun:test";
import { JSDOM } from "jsdom";
import { attach, detach, HandoffOps, readHostFile, recallFromOutside, type ComposerTarget } from "./composerHandoff";

const b64 = (text: string) => btoa(text);

/** A host that serves `bytes` for token "t1" in chunks of `chunk`. */
function host(bytes: string, chunk = 3) {
  const call = mock(async (op: string, params: unknown) => {
    expect(op).toBe(HandoffOps.read);
    const { token, offset } = params as { token: string; offset: number };
    if (token !== "t1") throw new Error("unknown token");
    return { data: b64(bytes.slice(offset, offset + chunk)), size: bytes.length };
  });
  return { call: call as never, calls: call };
}

function composer(takesFiles = true) {
  const added: { files: File[]; group: string | undefined }[] = [];
  const target: ComposerTarget = {
    takesFiles,
    addFiles: (files, group) => void added.push({ files: [...files], group }),
    removeGroup: mock((group: string) => group === "card-1"),
    quote: () => true,
    recallHistory: mock((_direction: "older" | "newer") => true),
  };
  return { target, added };
}

describe("composer hand-off", () => {
  it("reads a host file chunk by chunk", async () => {
    const { call, calls } = host("hello world", 4);
    const file = await readHostFile({ call }, { token: "t1", name: "a.txt", mimeType: "text/plain", size: 11 });
    expect(await file.text()).toBe("hello world");
    expect(file.name).toBe("a.txt");
    expect(file.type).toStartWith("text/plain");
    expect(calls).toHaveBeenCalledTimes(3);
  });

  it("reads an empty file in one call", async () => {
    const { call } = host("");
    const file = await readHostFile({ call }, { token: "t1", name: "e", mimeType: "", size: 0 });
    expect(file.size).toBe(0);
  });

  it("attaches the files to the composer, in their group", async () => {
    const { call } = host("abc");
    const { target, added } = composer();
    const files = [{ token: "t1", name: "card.md", mimeType: "text/markdown", size: 3 }];
    expect(await attach({ call }, () => target, { files, group: "card-1" })).toEqual({ attached: true });
    expect(added).toHaveLength(1);
    expect(added[0]!.group).toBe("card-1");
    expect(await added[0]!.files[0]!.text()).toBe("abc");
  });

  it("hands the files to the composer that shows once they are read (cmux#37736 round 10)", async () => {
    const { calls } = host("abc");
    const first = composer();
    const second = composer();
    let shown = first.target;
    const read = (op: string, params: unknown) => {
      shown = second.target; // the person opened another conversation while the bytes came
      return calls(op, params);
    };
    const files = [{ token: "t1", name: "card.md", mimeType: "text/markdown", size: 3 }];
    expect(await attach({ call: read as never }, () => shown, { files })).toEqual({ attached: true });
    expect(first.added).toHaveLength(0);
    expect(second.added).toHaveLength(1);
  });

  it("refuses without a composer that takes files, or with an unreadable file", async () => {
    const { call } = host("abc");
    const files = [{ token: "t1", name: "x", mimeType: "", size: 3 }];
    expect(await attach({ call }, () => undefined, { files })).toEqual({ attached: false, reason: "noComposer" });
    expect(await attach({ call }, () => composer(false).target, { files })).toEqual({
      attached: false,
      reason: "noComposer",
    });
    const gone = [{ token: "t2", name: "x", mimeType: "", size: 3 }];
    expect(await attach({ call }, () => composer().target, { files: gone })).toEqual({
      attached: false,
      reason: "unreadable",
    });
    expect(await attach({ call }, () => composer().target, { files: [] })).toEqual({
      attached: false,
      reason: "noFiles",
    });
  });

  it("takes a group back", () => {
    const { target } = composer();
    expect(detach(target, { group: "card-1" })).toEqual({ removed: true });
    expect(detach(target, { group: "card-2" })).toEqual({ removed: false });
    expect(detach(target, { group: "../x y" })).toEqual({ removed: false });
    expect(detach(undefined, { group: "card-1" })).toEqual({ removed: false });
  });
});

describe("Up and Down from outside the box", () => {
  const { document, KeyboardEvent } = new JSDOM("<!doctype html><html><body></body></html>").window;
  function key(target: Element, init: KeyboardEventInit) {
    const event = new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
    Object.defineProperty(event, "target", { value: target });
    return event;
  }

  it("steps the history from the transcript and takes the key", () => {
    const { target } = composer();
    const rows = document.createElement("div");
    document.body.append(rows);
    const up = key(rows, { key: "ArrowUp" });
    expect(recallFromOutside(up, target)).toBe(true);
    expect(up.defaultPrevented).toBe(true);
    expect(recallFromOutside(key(rows, { key: "ArrowDown" }), target)).toBe(true);
    expect(target.recallHistory).toHaveBeenNthCalledWith(1, "older");
    expect(target.recallHistory).toHaveBeenNthCalledWith(2, "newer");
    rows.remove();
  });

  it("leaves fields, lists, chords and other keys their own", () => {
    const { target } = composer();
    const field = document.createElement("input");
    const list = document.createElement("div");
    list.setAttribute("role", "listbox");
    const item = document.createElement("div");
    list.append(item);
    document.body.append(field, list);
    expect(recallFromOutside(key(field, { key: "ArrowUp" }), target)).toBe(false);
    expect(recallFromOutside(key(item, { key: "ArrowUp" }), target)).toBe(false);
    expect(recallFromOutside(key(document.body, { key: "ArrowUp", shiftKey: true }), target)).toBe(false);
    expect(recallFromOutside(key(document.body, { key: "ArrowLeft" }), target)).toBe(false);
    expect(target.recallHistory).not.toHaveBeenCalled();
    field.remove();
    list.remove();
  });

  it("does nothing without a composer, and leaves the key when the history has nothing", () => {
    expect(recallFromOutside(key(document.body, { key: "ArrowUp" }), undefined)).toBe(false);
    const { target } = composer();
    target.recallHistory = mock(() => false);
    const up = key(document.body, { key: "ArrowUp" });
    expect(recallFromOutside(up, target)).toBe(false);
    expect(up.defaultPrevented).toBe(false);
  });
});
