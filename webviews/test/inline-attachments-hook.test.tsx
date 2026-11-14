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
// 7. one placement rule for every kind (Leo, 2026-11-09: "we have inline stuff, so why is this not
//    inline? This one went above the whole thing."): an image, a video, a file, a screenshot and a
//    Pasted text chip each go in at the caret, and one whose node a value from outside took away while
//    it loaded (as a slow video's read invites) goes at the prompt's start, never the strip above.
// 8. a paste placed after a commit painted but before that commit's effects ran (a second image
//    pasted the moment the first one's picture came) keeps its node where it went: that commit never
//    drew it, so its placeholder has not ended (composer-attach-no-jump.test.ts went red on this in
//    Chromium under load: the node left the text and its picture landed before the first).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, useLayoutEffect, useRef, useState } from "react";
import type { Root } from "react-dom/client";
import { inlineToken, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { PendingAttachment } from "../src/agent-session/acpmux/composer/attachmentIntakeModel";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { translate } from "../src/agent-session/acpmux/i18n";
import type { MarkdownFieldHandle } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
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
  setScope(next: string): void;
  keepInStrip(chips: PendingAttachment[]): void;
  place(chips: PendingAttachment[]): void;
  setPending(next: PendingAttachment[]): void;
  keepAsFile(id: string): void;
  /// Runs `run` in the next commit's layout phase: after that commit drew, before its effects ran.
  onNextCommit(run: () => void): void;
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
  const { usePastedChips } = await import("../src/agent-session/acpmux/composer/pastedChips");
  const field = createRef<MarkdownFieldHandle>();
  const controls = createRef<Controls>() as { current: Controls | null };
  function Harness() {
    const [text, setText] = useState(initial.text);
    const [attachments, setAttachmentsState] = useState<ComposerAttachment[]>(initial.attachments ?? []);
    const [placing, setPlacing] = useState(initial.placing ?? true);
    const [pending, setPending] = useState<PendingAttachment[]>(initial.pending ?? []);
    const [scope, setScope] = useState("first");
    const attachmentsRef = useRef(attachments);
    attachmentsRef.current = attachments;
    const setAttachments = (update: (current: ComposerAttachment[]) => ComposerAttachment[]) => {
      attachmentsRef.current = update(attachmentsRef.current);
      setAttachmentsState((current) => update(current));
    };
    // Keep as .txt, as the composer wires it (ComposerBox.tsx): the intake makes the file's chip at
    // once and places it, at the start when the pasted chip had no node.
    const placeFile = useRef<(chips: PendingAttachment[], start: boolean) => void>(() => {});
    const pasted = usePastedChips(attachmentsRef, setAttachments, field, (file, inText = true) => {
      const made: ComposerAttachment = {
        id: "kept-txt",
        kind: "link",
        name: file.name,
        mimeType: file.type,
        size: 1,
        path: "/tmp/Pasted text.txt",
      };
      setAttachments((current) => [...current, made]);
      placeFile.current([{ id: made.id, name: made.name, image: false } as PendingAttachment], !inText);
    });
    const inline = useInlineAttachments({
      keepFile: pasted.keepAsFile,
      field,
      scope,
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
    // After the hook's own layout effects: what a paste does between a commit and its effects.
    const nextCommit = useRef<(() => void) | undefined>(undefined);
    useLayoutEffect(() => {
      const run = nextCommit.current;
      nextCommit.current = undefined;
      run?.();
    });
    controls.current = {
      attachments: () => attachmentsRef.current,
      setAttachments: (next) => setAttachmentsState(next),
      setPlacing,
      setText,
      sent: (ids) => inline.sent(ids),
      setScope,
      keepInStrip: (chips) => inline.place(chips, undefined, true),
      place: (chips) => inline.place(chips, "drop"),
      setPending,
      keepAsFile: (id) => inline.keepFile(id),
      onNextCommit: (run) => {
        nextCommit.current = run;
      },
    };
    placeFile.current = (chips, start) => inline.place(chips, undefined, start);
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
        {/* The inline view's strip: only what is not placed in the text (ComposerBox.tsx). */}
        <div
          data-unplaced={attachments
            .filter((chip) => !inline.inText(text).has(chip.id))
            .map((chip) => chip.id)
            .join(" ")}
        />
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

// A chip kept as a file where it had no node in the text (pastedChips.ts keepAsFile) goes at the
// start of the prompt, never at the caret and never left in the strip (Leo, 2026-11-09: "we have
// inline stuff, so why is this not inline?"); across a scope change it is placed once, not again.
test("a file kept where it had no node goes at the prompt's start, once, across a scope change", async () => {
  const { field, controls } = await render({ text: "look", placing: true });
  await act(async () => field.current!.setCaret(4));
  await act(async () => {
    controls.keepInStrip([{ ...FILE } as unknown as PendingAttachment]);
    controls.setAttachments([FILE]);
  });
  for (let turn = 0; turn < 5; turn++) await settle();
  expect(nodes()).toEqual([FILE.id]);
  expect(field.current!.value().indexOf("look")).toBeGreaterThan(field.current!.value().indexOf(FILE.id));
  await act(async () => controls.setScope("second"));
  for (let turn = 0; turn < 5; turn++) await settle();
  await act(async () => controls.setAttachments([{ ...FILE }]));
  for (let turn = 0; turn < 5; turn++) await settle();
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

test("a video's play in the text plays it as the strip's does (Quick Look when the host grants no stream)", async () => {
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
  await until(() => calls.some(([method]) => method === "video.quickLook"));
  expect(calls.filter(([method]) => method === "media.load")).toEqual([["media.load", { src: VIDEO.path }]]);
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

/// Every kind a person adds, as its read makes it.
const KINDS: { label: string; attachment: ComposerAttachment; pending: Partial<PendingAttachment> }[] = [
  {
    label: "a screenshot",
    attachment: { id: "k-shot", kind: "image", name: "Screenshot.png", mimeType: "image/png", size: 3, data: "AAAA" },
    pending: { image: true },
  },
  {
    label: "a video",
    attachment: {
      id: "k-video",
      kind: "link",
      name: "Screen Recording.mov",
      mimeType: "video/quicktime",
      size: 48_000_000,
      path: "/Users/dev/Desktop/Screen Recording.mov",
    },
    pending: { video: true },
  },
  { label: "a file", attachment: { ...FILE, id: "k-file" }, pending: {} },
  {
    label: "a PDF",
    attachment: {
      id: "k-pdf",
      kind: "link",
      name: "spec.pdf",
      mimeType: "application/pdf",
      size: 9,
      path: "/tmp/spec.pdf",
    },
    pending: {},
  },
  {
    label: "a Pasted text chip",
    attachment: {
      id: "k-pasted",
      kind: "pasted",
      name: "Pasted text",
      mimeType: "text/plain",
      size: 5,
      text: "a\nb\nc",
    },
    pending: {},
  },
];

const unplaced = () => host.querySelector("[data-unplaced]")?.getAttribute("data-unplaced") ?? "";

for (const { label, attachment, pending } of KINDS) {
  const chip = { id: attachment.id, name: attachment.name, image: false, ...pending } as PendingAttachment;

  test(`${label} added at the caret loads there and stays in the text`, async () => {
    const { field, controls } = await render({ text: "hello world" });
    await act(async () => field.current!.setCaret("hello ".length));
    await act(async () => {
      controls.setPending([chip]);
      controls.place([chip]);
    });
    expect(nodes()).toEqual([attachment.id]);
    await act(async () => {
      controls.setPending([]);
      controls.setAttachments([attachment]);
    });
    for (let turn = 0; turn < 3; turn++) await settle();
    expect(nodes()).toEqual([attachment.id]);
    expect(unplaced()).toBe("");
    const value = field.current!.value();
    expect(value.indexOf(attachment.id)).toBeGreaterThan(value.indexOf("hello"));
    expect(value.indexOf(attachment.id)).toBeLessThan(value.indexOf("world"));
  });

  test(`${label} whose node a value from outside took away while it loaded lands at the prompt's start, not the strip`, async () => {
    const { field, controls } = await render({ text: "hello" });
    await act(async () => field.current!.setCaret(5));
    await act(async () => {
      controls.setPending([chip]);
      controls.place([chip]);
    });
    expect(nodes()).toEqual([attachment.id]);
    // A chat's draft read, a carried prompt: the text is replaced, its node gone, the read still out.
    await act(async () => controls.setText("hello there"));
    await settle();
    expect(nodes()).toEqual([]);
    await act(async () => field.current!.setCaret("hello th".length));
    await act(async () => {
      controls.setPending([]);
      controls.setAttachments([attachment]);
    });
    for (let turn = 0; turn < 3; turn++) await settle();
    expect(nodes()).toEqual([attachment.id]);
    expect(unplaced()).toBe("");
    // At the start, never between the letters typed meanwhile.
    const value = field.current!.value();
    expect(value.indexOf(attachment.id)).toBeLessThan(value.indexOf("hello there"));
    expect(value).toContain("hello there");
  });
}

// Router review of #39955 (F1): Keep as .txt on a Pasted text chip that has no node (a value from
// outside took it away) puts the file in the text; an undo then brings the paste back, never leaves
// the draft with neither the paste nor its file.
test("Keep as .txt on a node-less pasted chip survives an undo", async () => {
  const PASTED = {
    id: "k-pasted",
    kind: "pasted",
    name: "Pasted text",
    mimeType: "text/plain",
    size: 5,
    text: "a\nb\nc",
  } as ComposerAttachment;
  const { field, controls } = await render({ text: `hello ${inlineToken(PASTED.id)}`, attachments: [PASTED] });
  await until(() => nodes().includes(PASTED.id));
  // A value from outside: the node goes, the chip stays (drawn in the strip until placed).
  await act(async () => controls.setText("hello there"));
  await settle();
  expect(nodes()).toEqual([]);
  expect(controls.attachments().map((chip) => chip.id)).toEqual([PASTED.id]);
  // Later than the editor's undo grouping (500 ms, read from each transaction's Date.now), as a
  // person's click is: its own undo step. The clock moves on instead of the test waiting.
  const realNow = Date.now;
  const later = realNow() + 1000;
  Date.now = () => later;
  try {
    await act(async () => controls.keepAsFile(PASTED.id));
  } finally {
    Date.now = realNow;
  }
  for (let turn = 0; turn < 3; turn++) await settle();
  expect(nodes()).toEqual(["kept-txt"]);
  expect(controls.attachments().map((chip) => chip.id)).toEqual(["kept-txt"]);
  await act(async () => field.current!.undo());
  for (let turn = 0; turn < 3; turn++) await settle();
  const held = controls.attachments().map((chip) => chip.id);
  expect(held.includes(PASTED.id) || held.includes("kept-txt")).toBe(true);
  expect(nodes().some((id) => held.includes(id!))).toBe(true);
  expect(field.current!.value()).toContain("hello there");
});

test("a paste placed before the last commit's effects ran keeps its node, after the attachment before it", async () => {
  const first = { id: "first-shot", name: "first.png", image: true } as PendingAttachment;
  const second = { id: "second-shot", name: "second.png", image: true } as PendingAttachment;
  const ready: ComposerAttachment = {
    id: first.id,
    kind: "link",
    name: "first.png",
    mimeType: "image/png",
    size: 5,
    path: "/tmp/first.png",
  };
  const { controls } = await render({ text: "", pending: [first] });
  await act(async () => controls.place([first]));
  await settle();
  expect(nodes()).toEqual([first.id]);
  // The first one's picture comes: a commit with it a chip and nothing loading. The second paste is
  // placed after that commit drew and before its effects ran, as the intake places a paste in its
  // own task (attachmentIntakeModel.ts `intake`), its placeholder drawn by the next render.
  await act(async () => {
    controls.onNextCommit(() => {
      controls.place([second]);
      controls.setPending([second]);
    });
    controls.setPending([]);
    controls.setAttachments([ready]);
  });
  for (let turn = 0; turn < 3; turn++) await settle();
  // Still in the text, where it was placed: after the first.
  expect(nodes()).toEqual([first.id, second.id]);
});
