// A sent prompt follows the attachment view (`agentPane.attachmentView`, composerSettings.ts). Leo:
// "the actual input, as a default, I don't think it's gonna be worse to put the things inline, like
// how iMessage on Mac does it." Inline (the default) draws each picture and file in the text where it
// was added; Strip draws them in a row above the bubble, in the same order, and the bubble keeps the
// text alone. Switching is only a look: the row's parts, their order and an open edit stay as they are.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings({ attachmentView: "inline" });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const PNG = "data:image/png;base64,iVBORw0KGgo=";
const row: AcpmuxRow = {
  id: "user-7",
  version: 1,
  at: Date.now(),
  kind: "user",
  seq: 7,
  text: "Before this between that after.",
  inlineParts: [
    { kind: "text", text: "Before " },
    { kind: "image", id: "shot-a", mimeType: "image/png", name: "a.png", src: PNG },
    { kind: "text", text: "this between " },
    { kind: "document", id: "spec", name: "spec.pdf", mimeType: "application/pdf" },
    { kind: "image", id: "shot-b", mimeType: "image/png", name: "b.png", src: PNG },
    { kind: "text", text: "that after." },
  ],
};
const parts = structuredClone(row.inlineParts);

async function draw(actions: object = {}, drawn: AcpmuxRow = row) {
  const { createRoot } = await import("react-dom/client");
  const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
  const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <TurnActionsContext.Provider value={actions}>
        <UserBubble row={drawn} text={drawn.text ?? ""} />
      </TurnActionsContext.Provider>,
    ),
  );
}

async function view(attachmentView: "inline" | "strip") {
  const { setAttachmentView } = await import("../src/agent-session/acpmux/composerSettings");
  await act(async () => setAttachmentView(attachmentView));
}

/// Each item in reading order: `text:<text>` for text, `<kind>:<id or name>` for an attachment.
const items = (container: Element | null) =>
  [...(container?.querySelectorAll<HTMLElement>("[data-part]") ?? [])].map((node) => node.dataset.part);

const bubble = () => host.querySelector(".cv-user__bubble");
const strip = () => host.querySelector("[data-attachment-view=strip]");

const INLINE = [
  "text:Before ",
  "image:shot-a",
  "text:this between ",
  "document:spec.pdf",
  "image:shot-b",
  "text:that after.",
];

test("Inline, then Strip, then Inline: same text, same attachments, same order", async () => {
  await draw();
  expect(items(bubble())).toEqual(INLINE);
  expect(strip()).toBeNull();

  await view("strip");
  // Every attachment, every kind, in the row above the bubble, in the order it was added.
  expect(items(strip())).toEqual(["image:shot-a", "document:spec.pdf", "image:shot-b"]);
  // The bubble keeps the text alone, its runs in order.
  expect(items(bubble())).toEqual(["text:Before ", "text:this between ", "text:that after."]);
  expect(bubble()!.textContent).toBe("Before this between that after.");

  await view("inline");
  expect(items(bubble())).toEqual(INLINE);
  expect(strip()).toBeNull();
  // Only a look: the row's stored parts are untouched.
  expect(row.inlineParts).toEqual(parts);
});

test("an open edit and its draft stay open across a switch", async () => {
  await draw({ edit: { seqs: new Map([["user-7", 6]]), send: async () => true } });
  const edit = host.querySelector<HTMLButtonElement>('.cv-user__actions button[aria-label="Edit"]')!;
  await act(async () => edit.click());
  const field = host.querySelector<HTMLTextAreaElement>(".cv-user__edit-field")!;
  const setValue = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(field, "draft kept");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  await view("strip");
  expect(host.querySelector(".cv-user__edit-field")).toBe(field);
  expect(field.value).toBe("draft kept");
  await view("inline");
  expect(host.querySelector<HTMLTextAreaElement>(".cv-user__edit-field")?.value).toBe("draft kept");
});

// A prompt whose last part is an attachment (text, then what was added after it) reads in that order
// too: Inline puts the attachment after its text in the bubble, never above it; Strip puts it in the
// row above. A prompt of attachments alone draws them with no empty bubble, in either view.
const trailing = (id: string, inlineParts: AcpmuxRow["inlineParts"], text = ""): AcpmuxRow => ({
  id,
  version: 1,
  at: Date.now(),
  kind: "user",
  seq: 9,
  text,
  inlineParts,
});

for (const [name, last, part] of [
  ["an image", { kind: "image", id: "shot-c", mimeType: "image/png", name: "c.png", src: PNG }, "image:shot-c"],
  ["a file", { kind: "file", id: "log", name: "build.log", mimeType: "text/plain" }, "file:build.log"],
] as const) {
  test(`text then ${name}: Inline in the bubble after the text, Strip above it`, async () => {
    await draw({}, trailing("user-9", [{ kind: "text", text: "See this: " }, last], "See this:"));
    expect(items(bubble())).toEqual(["text:See this: ", part]);
    expect(strip()).toBeNull();
    // Never the old band of images above the bubble.
    expect(host.querySelector(".cv-user__images:not([data-attachment-view])")).toBeNull();
    await view("strip");
    expect(items(strip())).toEqual([part]);
    expect(items(bubble())).toEqual(["text:See this: "]);
    await view("inline");
    expect(items(bubble())).toEqual(["text:See this: ", part]);
  });
}

test("an image alone draws the image and no bubble, in either view", async () => {
  const only = { kind: "image", id: "shot-d", mimeType: "image/png", name: "d.png", src: PNG } as const;
  await draw({}, trailing("user-10", [only]));
  expect(bubble()).toBeNull();
  expect(items(strip())).toEqual(["image:shot-d"]);
  await view("strip");
  expect(bubble()).toBeNull();
  expect(items(strip())).toEqual(["image:shot-d"]);
});
