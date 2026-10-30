import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { installFileDropLifecycle } from "../src/agent-session/acpmux/attachments";

type EventView = { Event: typeof Event };

function fileEvent(view: EventView, type: string, files: File[]): DragEvent {
  const event = new view.Event(type, { bubbles: true, cancelable: true }) as DragEvent;
  Object.defineProperty(event, "dataTransfer", {
    value: { files, types: ["Files"] },
  });
  return event;
}

describe("composer file-drop lifecycle", () => {
  test("keeps nested file drags active until the matching leave", () => {
    const dom = new JSDOM("<!doctype html><body><div id='child'></div></body>");
    const view = dom.window as unknown as EventView;
    const child = dom.window.document.querySelector("#child")!;
    const file = new dom.window.File(["draft"], "draft.txt", { type: "text/plain" }) as unknown as File;
    const active: boolean[] = [];
    const remove = installFileDropLifecycle(
      () => {},
      (value) => active.push(value),
      dom.window.document,
      dom.window as unknown as Window,
    );
    child.dispatchEvent(fileEvent(view, "dragenter", [file]));
    child.dispatchEvent(fileEvent(view, "dragenter", [file]));
    child.dispatchEvent(fileEvent(view, "dragleave", [file]));
    expect(active).toEqual([true, true]);
    expect(active.at(-1)).toBe(true);
    const leave = fileEvent(view, "dragleave", [file]);
    child.dispatchEvent(leave);
    expect(leave.defaultPrevented).toBe(false);
    expect(active.at(-1)).toBe(false);
    remove();
  });

  test("resets on window blur and delivers files once on drop", () => {
    const dom = new JSDOM("<!doctype html><body></body>");
    const view = dom.window as unknown as EventView;
    const file = new dom.window.File(["draft"], "draft.txt", { type: "text/plain" }) as unknown as File;
    const active: boolean[] = [];
    const dropped: File[][] = [];
    const remove = installFileDropLifecycle(
      (files) => dropped.push(files),
      (value) => active.push(value),
      dom.window.document,
      dom.window as unknown as Window,
    );
    dom.window.document.body.dispatchEvent(fileEvent(view, "dragenter", [file]));
    dom.window.dispatchEvent(new dom.window.Event("blur"));
    expect(active.at(-1)).toBe(false);
    const drop = fileEvent(view, "drop", [file]);
    dom.window.document.body.dispatchEvent(drop);
    expect(drop.defaultPrevented).toBe(true);
    expect(dropped).toHaveLength(1);
    expect(dropped[0]?.[0]?.name).toBe("draft.txt");
    remove();
  });
});
