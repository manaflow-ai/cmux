// The composer's placed attachments (composer/inlineAttachments.tsx) with a field whose value the
// consumer holds, as the New Tab page holds its own (#26567's review at 91b9614b):
// 1. a draft read before its attachments came keeps their tokens as text: once they come, each is
//    its attachment in the text;
// 2. attachments added while nothing is placed in the text (the strip view, shell mode) go into it
//    when placing starts;
// 3. a sent attachment is gone for good: an undo of the send's clear brings back no node of it.
// 4. a PDF, a video and a file in the text are the strip's own chips (#26545's review at 2b4ccd42):
//    the same open, play and remove controls, doing the same things;
// 5. an image in the text that cannot be drawn says so, as the strip's does, with Retry and Remove.
// 6. a loading chip's node deleted and brought back by undo loads again under its id (#26545's
//    review at 17b50e79); one whose file is not kept leaves the text, never an empty atom.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, useRef, useState } from "react";
import type { Root } from "react-dom/client";
import { inlineToken, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { PendingAttachment } from "../src/agent-session/acpmux/composer/attachmentIntake";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { translate } from "../src/agent-session/acpmux/i18n";
import type { MarkdownFieldHandle } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
  "MouseEvent",
  "Event",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    MouseEvent: window.MouseEvent,
    Event: window.Event,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  setChipHost(undefined);
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
async function until(ready: () => boolean) {
  for (let turn = 0; turn < 200 && !ready(); turn++) await settle();
}

const FILE: ComposerAttachment = {
  id: "kept-later",
  kind: "link",
  name: "notes.txt",
  mimeType: "text/plain",
  size: 5,
  path: "/tmp/notes.txt",
};

type Controls = {
  attachments(): ComposerAttachment[];
  setAttachments(next: ComposerAttachment[]): void;
  setPlacing(on: boolean): void;
  setText(next: string): void;
  sent(ids: string[]): void;
};

/// A field and the hook, as the New Tab page wires them: the consumer holds the value and the
/// attachments, and draws the hook's chips.
async function render(initial: {
  text: string;
  attachments?: ComposerAttachment[];
  placing?: boolean;
  /// The strip too, with the same attachments: what the chips in the text are held to.
  strip?: boolean;
  pending?: PendingAttachment[];
  /// The intake's revive (attachmentIntake.tsx): whether the chip's file is kept to read again.
  revives?: boolean;
  /// Why a staged image's original failed to upload, by id (attachmentIntake.tsx `originalFailures`).
  originalFailures?: Readonly<Record<string, string>>;
}) {
  const { createRoot } = await import("react-dom/client");
  const { AttachmentStrip } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  const { useInlineAttachments } = await import("../src/agent-session/acpmux/composer/inlineAttachments");
  const field = createRef<MarkdownFieldHandle>();
  const controls = createRef<Controls>() as { current: Controls | null };
  function Harness() {
    const [text, setText] = useState(initial.text);
    const [attachments, setAttachmentsState] = useState<ComposerAttachment[]>(initial.attachments ?? []);
    const [placing, setPlacing] = useState(initial.placing ?? true);
    const [pending, setPending] = useState<PendingAttachment[]>(initial.pending ?? []);
    const attachmentsRef = useRef(attachments);
    attachmentsRef.current = attachments;
    const inline = useInlineAttachments({
      field,
      text,
      attachments,
      attachmentsRef,
      setAttachments: (update) => setAttachmentsState((current) => update(current)),
      pending,
      cancel: (id) => {
        calls.push(`cancel ${id}`);
        setPending((chips) => chips.filter((chip) => chip.id !== id));
      },
      retry: (id) => calls.push(`retry ${id}`),
      revive: (id) => {
        calls.push(`revive ${id}`);
        const chip = initial.pending?.find((each) => each.id === id);
        if (!initial.revives || !chip) return false;
        setPending((chips) => [...chips, chip]);
        return true;
      },
      expand: () => {},
      placing: () => placing,
      ...(initial.originalFailures ? { originalFailures: initial.originalFailures } : {}),
    });
    controls.current = {
      attachments: () => attachmentsRef.current,
      setAttachments: (next) => setAttachmentsState(next),
      setPlacing,
      setText,
      sent: (ids) => inline.sent(ids),
    };
    return (
      <>
        <MarkdownField
          ref={field}
          value={text}
          onChange={(value) => {
            inline.edited(value);
            setText(value);
          }}
          onInlineViews={inline.onInlineViews}
          isInlineAttachment={inline.known}
        />
        {inline.chips}
        {initial.strip && <AttachmentStrip attachments={attachments} onRemove={() => {}} />}
      </>
    );
  }
  const calls: string[] = [];
  root = createRoot(host);
  await act(async () => root!.render(<Harness />));
  await until(() => !!field.current?.element() && !!host.querySelector(".acpmux-md"));
  for (let turn = 0; turn < 5; turn++) await settle();
  return { field, controls: controls.current!, calls };
}

const nodes = () =>
  [...host.querySelectorAll("[data-inline-attachment]")].map((node) => node.getAttribute("data-inline-attachment"));
const text = () => host.querySelector(".acpmux-md")?.textContent ?? "";

test("a draft read before its attachment came places it once it comes", async () => {
  const { controls } = await render({ text: `read ${inlineToken(FILE.id)} please` });
  // Before it comes the token is already its node, drawing nothing: never the token's text
  // (composer/inlineNode.ts placeTokensIn reads a token of an unknown id as a node too).
  expect(nodes()).toEqual([FILE.id]);
  expect(text()).not.toContain(FILE.id);
  expect(host.querySelector(".acpmux-md-inline-chip")).toBeNull();
  await act(async () => controls.setAttachments([FILE]));
  await until(() => nodes().includes(FILE.id));
  expect(nodes()).toEqual([FILE.id]);
  expect(text()).not.toContain(FILE.id);
  await until(() => !!host.querySelector(".acpmux-md-inline-chip"));
  expect(host.querySelector(".acpmux-md-inline-chip")?.textContent).toContain("notes.txt");
});

test("attachments added while nothing is placed go into the text when placing starts", async () => {
  const { controls } = await render({ text: "look", attachments: [FILE], placing: false });
  expect(nodes()).toEqual([]);
  await act(async () => controls.setPlacing(true));
  await until(() => nodes().includes(FILE.id));
  expect(nodes()).toEqual([FILE.id]);
});

test("an undo of a send's clear brings back no node of what was sent", async () => {
  const { field, controls } = await render({ text: `see ${inlineToken(FILE.id)}`, attachments: [FILE] });
  await until(() => nodes().includes(FILE.id));
  // The send: the attachments went, the prompt clears.
  await act(async () => {
    controls.sent([FILE.id]);
    controls.setAttachments([]);
    controls.setText("");
  });
  await settle();
  expect(nodes()).toEqual([]);
  await act(async () => field.current!.undo());
  await settle();
  await settle();
  expect(nodes()).toEqual([]);
  expect(text()).toContain("see");
});

const POSTER = "data:image/jpeg;base64,/9j/AA==";
const PDF: ComposerAttachment = {
  id: "inline-pdf",
  kind: "document",
  name: "brief.pdf",
  mimeType: "application/pdf",
  size: 4,
  data: btoa("%PDF"),
  pageCount: 3,
};
const VIDEO: ComposerAttachment = {
  id: "inline-video",
  kind: "link",
  name: "demo.mov",
  mimeType: "video/quicktime",
  size: 48_000_000,
  path: "/tmp/demo.mov",
  video: { durationMs: 42_400, width: 1920, height: 1080, poster: POSTER, frames: [] },
};
const DOCUMENT: ComposerAttachment = {
  id: "inline-doc",
  kind: "link",
  name: "report.docx",
  mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  size: 12_345,
  path: "/tmp/report.docx",
};
const IMAGE: ComposerAttachment = {
  id: "inline-image",
  kind: "image",
  name: "shot.png",
  mimeType: "image/png",
  size: 4,
  data: "AAAA",
};

const inlineChip = (id: string) => host.querySelector<HTMLElement>(`[data-inline-attachment="${id}"]`);
const stripChip = () => host.querySelector<HTMLElement>(".acpmux-attachments .acpmux-attachment")!;
/// A chip's controls as a person finds them: each button or link by its name.
const controlsOf = (chip: HTMLElement) =>
  [...chip.querySelectorAll<HTMLElement>("button, a[href]")].map(
    (control) => control.getAttribute("aria-label") ?? control.textContent?.trim() ?? "",
  );

for (const [label, attachment] of [
  ["a PDF", PDF],
  ["a video", VIDEO],
  ["a document", DOCUMENT],
] as const)
  test(`${label} in the text has its strip chip's preview, open, play and remove controls`, async () => {
    await render({ text: `see ${inlineToken(attachment.id)} here`, attachments: [attachment], strip: true });
    await until(() => !!inlineChip(attachment.id)?.querySelector("button"));
    const strip = controlsOf(stripChip());
    expect(strip.length).toBeGreaterThan(0);
    expect(controlsOf(inlineChip(attachment.id)!)).toEqual(strip);
    // What the strip chip shows of it (a PDF's sheet and pages, a video's poster and length, a file's
    // name and size) shows in the text too.
    const look = (chip: HTMLElement) =>
      [
        ...chip.querySelectorAll(
          ".acpmux-pdf-sheet, .acpmux-attachment-document-pages, .acpmux-attachment-video-length, .acpmux-file-chip",
        ),
      ].map((node) => `${node.className}:${node.textContent}`);
    expect(look(inlineChip(attachment.id)!)).toEqual(look(stripChip()));
  });

test("a PDF's open in the text opens the strip's PDF viewer", async () => {
  await render({ text: `see ${inlineToken(PDF.id)}`, attachments: [PDF] });
  await until(() => !!inlineChip(PDF.id)?.querySelector("button"));
  const open = inlineChip(PDF.id)!.querySelector<HTMLButtonElement>(
    `button[aria-label="${translate("composer.openAttachment", { name: PDF.name })}"]`,
  );
  expect(open).not.toBeNull();
  await act(async () => open!.click());
  await until(() => !!document.querySelector(".acpmux-pdf-viewer"));
  expect(document.querySelector(".acpmux-pdf-viewer")?.textContent).toContain(PDF.name);
});

test("a video's play in the text plays it in Quick Look, as the strip's does", async () => {
  const calls: [string, unknown][] = [];
  setChipHost(async (method, params) => {
    calls.push([method, params]);
    return undefined;
  });
  await render({ text: `see ${inlineToken(VIDEO.id)}`, attachments: [VIDEO] });
  await until(() => !!inlineChip(VIDEO.id)?.querySelector("button"));
  const play = inlineChip(VIDEO.id)!.querySelector<HTMLButtonElement>(
    `button[aria-label="${translate("composer.playVideo", { name: VIDEO.name, length: "0:42" })}"]`,
  );
  expect(play).not.toBeNull();
  await act(async () => play!.click());
  expect(calls.filter(([method]) => method === "video.quickLook")).toEqual([["video.quickLook", { src: VIDEO.path }]]);
});

for (const [label, attachment] of [
  ["a PDF", PDF],
  ["a video", VIDEO],
  ["a document", DOCUMENT],
] as const)
  test(`${label}'s remove in the text takes it out of the prompt`, async () => {
    const { controls } = await render({ text: `see ${inlineToken(attachment.id)} here`, attachments: [attachment] });
    await until(() => !!inlineChip(attachment.id)?.querySelector("button"));
    const remove = inlineChip(attachment.id)!.querySelector<HTMLButtonElement>(
      `button[aria-label="${translate("composer.removeAttachment", { name: attachment.name })}"]`,
    );
    expect(remove).not.toBeNull();
    await act(async () => remove!.click());
    await until(() => nodes().length === 0);
    expect(nodes()).toEqual([]);
    expect(controls.attachments()).toEqual([]);
  });

test("an image in the text that cannot be drawn says so, with Retry and Remove that work", async () => {
  const { controls } = await render({ text: `look ${inlineToken(IMAGE.id)} here`, attachments: [IMAGE] });
  await until(() => !!inlineChip(IMAGE.id)?.querySelector("img"));
  const fail = () =>
    act(async () => void inlineChip(IMAGE.id)!.querySelector("img")!.dispatchEvent(new Event("error")));
  const fallback = () => inlineChip(IMAGE.id)?.querySelector<HTMLElement>(".acpmux-attachment-image-failed");
  await fail();
  await until(() => !!fallback());
  expect(fallback()?.querySelector(".acpmux-attachment-failed-text")?.textContent).toBe(translate("image.failed"));
  expect(inlineChip(IMAGE.id)!.querySelector("img")).toBeNull();
  // Retry draws it again.
  // One small retry glyph button, named Retry, never a text link.
  const retry = fallback()!.querySelector<HTMLButtonElement>(".acpmux-attachment-retry") ?? undefined;
  expect(retry?.getAttribute("aria-label")).toBe(translate("composer.retryAttachment"));
  expect(retry?.textContent).toBe("");
  expect(retry).toBeDefined();
  await act(async () => retry!.click());
  await until(() => !!inlineChip(IMAGE.id)?.querySelector("img"));
  expect(fallback()).toBeFalsy();
  // Remove takes it out of the prompt.
  await fail();
  await until(() => !!fallback());
  const remove = fallback()!.querySelector<HTMLButtonElement>(
    `button[aria-label="${translate("composer.removeAttachment", { name: "shot.png" })}"]`,
  );
  expect(remove).not.toBeNull();
  await act(async () => remove!.click());
  await until(() => nodes().length === 0);
  expect(nodes()).toEqual([]);
  expect(controls.attachments()).toEqual([]);
});

const LOADING: PendingAttachment = { id: "loading-zip", name: "build-logs.zip", image: false };

for (const revives of [true, false])
  test(`a loading chip's node deleted, then undone, ${revives ? "loads again in its place" : "leaves the text"}`, async () => {
    const { field, calls } = await render({
      text: `logs ${inlineToken(LOADING.id)} here`,
      pending: [LOADING],
      revives,
    });
    await until(() => nodes().includes(LOADING.id));
    await act(async () => field.current!.removeInline(LOADING.id));
    await settle();
    expect(nodes()).toEqual([]);
    expect(calls).toEqual([`cancel ${LOADING.id}`]);
    await act(async () => field.current!.undo());
    await settle();
    await settle();
    expect(calls).toEqual([`cancel ${LOADING.id}`, `revive ${LOADING.id}`]);
    if (revives) {
      expect(nodes()).toEqual([LOADING.id]);
      await until(() => !!host.querySelector(".acpmux-md-inline-chip[data-state='loading']"));
      expect(host.querySelector(".acpmux-md-inline-chip[data-state='loading']")).not.toBeNull();
    } else expect(nodes()).toEqual([]);
    expect(text()).toContain("logs");
  });

// Review of #26545 at a29c21e7: inline is the default view, so an image whose original failed to
// upload must show its Retry in the text, as the strip's chip does (#28833).
test("an image in the text whose original failed to upload shows Retry, which retries it", async () => {
  const { calls } = await render({
    text: `look ${inlineToken(IMAGE.id)} here`,
    attachments: [IMAGE],
    originalFailures: { [IMAGE.id]: "The disk is full." },
  });
  await until(() => !!inlineChip(IMAGE.id)?.querySelector(".acpmux-attachment-original-retry"));
  const retry = inlineChip(IMAGE.id)!.querySelector<HTMLButtonElement>(".acpmux-attachment-original-retry")!;
  await act(async () => retry.click());
  expect(calls).toContain(`retry ${IMAGE.id}`);
});

test("an image in the text whose original did not fail shows no Retry", async () => {
  await render({ text: `look ${inlineToken(IMAGE.id)} here`, attachments: [IMAGE] });
  await until(() => !!inlineChip(IMAGE.id)?.querySelector("img"));
  expect(inlineChip(IMAGE.id)!.querySelector(".acpmux-attachment-original-retry")).toBeNull();
});
