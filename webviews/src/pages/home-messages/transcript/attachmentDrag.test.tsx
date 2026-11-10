// A drag that starts on a Home attachment is the host's (a Finder file promise): the page cancels
// its own drag at the start and hands the part, its message and its index to the host. Without a
// host the attachments do not drag at all.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { MessageAttachments } from "../../home-channels/AttachmentViews";
import type { HomeAttachment } from "../../home-channels/types";
import { createStrings } from "../../shared/i18n";
import { attachmentDragParams } from "../detail/detailHost";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;
const strings = createStrings({ en: {} }, ["en"]);

const file: HomeAttachment = {
  type: "attachment",
  hash: "h-file",
  name: "notes.pdf",
  mimeType: "application/pdf",
  byteCount: 2048,
};
const clip: HomeAttachment = {
  type: "attachment",
  hash: "h-clip",
  name: "demo.mov",
  mimeType: "video/quicktime",
  byteCount: 9000,
  durationMs: 4000,
};

function mount(onDragOut?: (part: HomeAttachment) => void) {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() =>
    root!.render(
      <MessageAttachments
        conversation="c1"
        parts={[file, clip]}
        strings={strings}
        {...(onDragOut ? { onDragOut } : {})}
      />,
    ),
  );
  return dom.window.document;
}

function dragStart(element: Element): boolean {
  const event = new dom!.window.Event("dragstart", { bubbles: true, cancelable: true });
  act(() => void element.dispatchEvent(event));
  return event.defaultPrevented;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a drag on a file row or a clip's name goes to the host, and the page's own drag is cancelled", () => {
  const dragged: string[] = [];
  const doc = mount((part) => dragged.push(part.hash));
  const row = doc.querySelector(".hc-att-file")!;
  expect(row.getAttribute("draggable")).toBe("true");
  expect(dragStart(row)).toBe(true);
  const name = doc.querySelector(".hc-att-video .hc-att-name")!;
  expect(name.getAttribute("draggable")).toBe("true");
  expect(dragStart(name)).toBe(true);
  expect(dragged).toEqual(["h-file", "h-clip"]);
});

test("without a host the attachments do not drag", () => {
  const doc = mount();
  const row = doc.querySelector(".hc-att-file")!;
  expect(row.getAttribute("draggable")).toBeNull();
  expect(dragStart(row)).toBe(false);
});

test("the host gets the part's place and its fields, not the page's part type", () => {
  const params = attachmentDragParams({ id: "m7", conversation: "c1" }, file, 2);
  expect(params).toEqual({
    conversation: "c1",
    message: "m7",
    partIndex: 2,
    attachment: { hash: "h-file", name: "notes.pdf", mimeType: "application/pdf", byteCount: 2048 },
  });
});
